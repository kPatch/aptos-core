// Copyright © Aptos Foundation
// Parts of the project are originally copyright © Meta Platforms, Inc.
// SPDX-License-Identifier: Apache-2.0

pub(crate) mod vm_wrapper;

use crate::{
    adapter_common::{preprocess_transaction, PreprocessedTransaction},
    block_executor::vm_wrapper::AptosExecutorTask,
    counters::{
        BLOCK_EXECUTOR_CONCURRENCY, BLOCK_EXECUTOR_EXECUTE_BLOCK_SECONDS,
        BLOCK_EXECUTOR_SIGNATURE_VERIFICATION_SECONDS,
    },
    AptosVM,
};
use aptos_aggregator::delta_change_set::DeltaOp;
use aptos_block_executor::{
    errors::Error,
    executor::BlockExecutor,
    task::{
        Transaction as BlockExecutorTransaction,
        TransactionOutput as BlockExecutorTransactionOutput,
    },
};
use aptos_infallible::Mutex;
use aptos_state_view::{StateView, StateViewId};
use aptos_types::{
    block_executor::partitioner::{ExecutableTransactions, SubBlock, TransactionWithDependencies},
    executable::ExecutableTestType,
    state_store::state_key::StateKey,
    transaction::{Transaction, TransactionOutput, TransactionStatus},
    write_set::WriteOp,
};
use aptos_vm_logging::{flush_speculative_logs, init_speculative_logs};
use aptos_vm_types::output::VMOutput;
use move_core_types::vm_status::VMStatus;
use once_cell::sync::OnceCell;
use rayon::{prelude::*, ThreadPool};
use std::sync::Arc;

impl BlockExecutorTransaction for PreprocessedTransaction {
    type Key = StateKey;
    type Value = WriteOp;
}

// Wrapper to avoid orphan rule
#[derive(Debug)]
pub(crate) struct AptosTransactionOutput {
    vm_output: Mutex<Option<VMOutput>>,
    committed_output: OnceCell<TransactionOutput>,
}

impl AptosTransactionOutput {
    pub(crate) fn new(output: VMOutput) -> Self {
        Self {
            vm_output: Mutex::new(Some(output)),
            committed_output: OnceCell::new(),
        }
    }

    fn take_output(mut self) -> TransactionOutput {
        match self.committed_output.take() {
            Some(output) => output,
            None => self
                .vm_output
                .lock()
                .take()
                .expect("Output must be set")
                .output_with_delta_writes(vec![]),
        }
    }
}

impl BlockExecutorTransactionOutput for AptosTransactionOutput {
    type Txn = PreprocessedTransaction;

    /// Execution output for transactions that comes after SkipRest signal.
    fn skip_output() -> Self {
        Self::new(VMOutput::empty_with_status(TransactionStatus::Retry))
    }

    /// Should never be called after incorporate_delta_writes, as it
    /// will consume vm_output to prepare an output with deltas.
    fn get_writes(&self) -> Vec<(StateKey, WriteOp)> {
        self.vm_output
            .lock()
            .as_ref()
            .expect("Output to be set to get writes")
            .write_set()
            .iter()
            .map(|(key, op)| (key.clone(), op.clone()))
            .collect()
    }

    /// Should never be called after incorporate_delta_writes, as it
    /// will consume vm_output to prepare an output with deltas.
    fn get_deltas(&self) -> Vec<(StateKey, DeltaOp)> {
        self.vm_output
            .lock()
            .as_ref()
            .expect("Output to be set to get deltas")
            .delta_change_set()
            .iter()
            .map(|(key, op)| (key.clone(), *op))
            .collect()
    }

    /// Can be called (at most) once after transaction is committed to internally
    /// include the delta outputs with the transaction outputs.
    fn incorporate_delta_writes(&self, delta_writes: Vec<(StateKey, WriteOp)>) {
        assert!(
            self.committed_output
                .set(
                    self.vm_output
                        .lock()
                        .take()
                        .expect("Output must be set to combine with deltas")
                        .output_with_delta_writes(delta_writes),
                )
                .is_ok(),
            "Could not combine VMOutput with deltas"
        );
    }

    /// Return the amount of gas consumed by the transaction.
    fn gas_used(&self) -> u64 {
        self.committed_output
            .get()
            .map_or(0, |output| output.gas_used())
    }
}

pub struct BlockAptosVM();

impl BlockAptosVM {
    fn verify_transactions(
        transactions: ExecutableTransactions<Transaction>,
    ) -> ExecutableTransactions<PreprocessedTransaction> {
        match transactions {
            ExecutableTransactions::Unsharded(transactions) => {
                let signature_verified_txns = transactions
                    .into_par_iter()
                    .with_min_len(25)
                    .map(preprocess_transaction::<AptosVM>)
                    .collect();
                ExecutableTransactions::Unsharded(signature_verified_txns)
            },
            ExecutableTransactions::Sharded(sub_blocks) => {
                let signature_verified_block = sub_blocks
                    .into_par_iter()
                    .map(|sub_block| {
                        let start_index = sub_block.start_index;
                        let verified_txns = sub_block
                            .into_transactions_with_deps()
                            .into_par_iter()
                            .with_min_len(25)
                            .map(|txn_with_deps| {
                                let TransactionWithDependencies {
                                    txn,
                                    cross_shard_dependencies,
                                } = txn_with_deps;
                                let preprocessed_txn = preprocess_transaction::<AptosVM>(txn);
                                TransactionWithDependencies::new(
                                    preprocessed_txn,
                                    cross_shard_dependencies,
                                )
                            })
                            .collect();
                        SubBlock::new(start_index, verified_txns)
                    })
                    .collect();
                ExecutableTransactions::Sharded(signature_verified_block)
            },
        }
    }

    pub fn execute_block<S: StateView + Sync>(
        executor_thread_pool: Arc<ThreadPool>,
        transactions: ExecutableTransactions<Transaction>,
        state_view: &S,
        concurrency_level: usize,
        maybe_block_gas_limit: Option<u64>,
    ) -> Result<Vec<TransactionOutput>, VMStatus> {
        let _timer = BLOCK_EXECUTOR_EXECUTE_BLOCK_SECONDS.start_timer();
        // Verify the signatures of all the transactions in parallel.
        // This is time consuming so don't wait and do the checking
        // sequentially while executing the transactions.
        // TODO: state sync runs this code but doesn't need to verify signatures
        let signature_verification_timer =
            BLOCK_EXECUTOR_SIGNATURE_VERIFICATION_SECONDS.start_timer();
        let signature_verified_block =
            executor_thread_pool.install(|| Self::verify_transactions(transactions));
        drop(signature_verification_timer);

        let num_txns = signature_verified_block.num_transactions();
        if state_view.id() != StateViewId::Miscellaneous {
            // Speculation is disabled in Miscellaneous context, which is used by testing and
            // can even lead to concurrent execute_block invocations, leading to errors on flush.
            init_speculative_logs(num_txns);
        }

        BLOCK_EXECUTOR_CONCURRENCY.set(concurrency_level as i64);
        let executor = BlockExecutor::<
            PreprocessedTransaction,
            AptosExecutorTask<S>,
            S,
            ExecutableTestType,
        >::new(
            concurrency_level,
            executor_thread_pool,
            maybe_block_gas_limit,
        );

        let ret = executor.execute_block(state_view, signature_verified_block, state_view);
        match ret {
            Ok(outputs) => {
                let output_vec: Vec<TransactionOutput> = outputs
                    .into_iter()
                    .map(|output| output.take_output())
                    .collect();

                // Flush the speculative logs of the committed transactions.
                let pos = output_vec.partition_point(|o| !o.status().is_retry());

                if state_view.id() != StateViewId::Miscellaneous {
                    // Speculation is disabled in Miscellaneous context, which is used by testing and
                    // can even lead to concurrent execute_block invocations, leading to errors on flush.
                    flush_speculative_logs(pos);
                }

                Ok(output_vec)
            },
            Err(Error::ModulePathReadWrite) => {
                unreachable!("[Execution]: Must be handled by sequential fallback")
            },
            Err(Error::UserError(err)) => Err(err),
        }
    }
}
