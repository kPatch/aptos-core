// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

use crate::{
    monitor,
    quorum_store::{batch_generator::BackPressure, counters, utils::ProofQueue},
};
use aptos_consensus_types::{
    common::{Payload, PayloadFilter, ProofWithData},
    proof_of_store::{BatchInfo, ProofOfStore},
    request_response::{GetPayloadCommand, GetPayloadResponse},
};
use aptos_logger::prelude::*;
use aptos_types::PeerId;
use futures::StreamExt;
use futures_channel::mpsc::Receiver;
use std::collections::HashSet;

#[derive(Debug)]
pub enum ProofManagerCommand {
    ReceiveProof(ProofOfStore),
    CommitNotification(u64, Vec<ProofOfStore>),
    Shutdown(tokio::sync::oneshot::Sender<()>),
}

pub struct ProofManager {
    proofs_for_consensus: ProofQueue,
    back_pressure_total_txn_limit: u64,
    remaining_total_txn_num: u64,
    back_pressure_total_proof_limit: u64,
    remaining_total_proof_num: u64,
}

impl ProofManager {
    pub fn new(
        my_peer_id: PeerId,
        back_pressure_total_txn_limit: u64,
        back_pressure_total_proof_limit: u64,
        max_in_future_usecs: u64,
        max_per_author: u64,
    ) -> Self {
        Self {
            proofs_for_consensus: ProofQueue::new(my_peer_id, max_in_future_usecs, max_per_author),
            back_pressure_total_txn_limit,
            remaining_total_txn_num: 0,
            back_pressure_total_proof_limit,
            remaining_total_proof_num: 0,
        }
    }

    pub(crate) fn receive_proof(&mut self, proof: ProofOfStore) {
        self.remaining_total_txn_num += proof.num_txns();
        self.remaining_total_proof_num += 1;
        self.proofs_for_consensus.push(proof);
    }

    pub(crate) fn handle_commit_notification(
        &mut self,
        block_timestamp: u64,
        batch_infos: Vec<BatchInfo>,
    ) {
        trace!(
            "QS: got clean request from execution at block timestamp {}",
            block_timestamp
        );

        self.proofs_for_consensus.mark_committed(batch_infos);
        self.proofs_for_consensus
            .handle_updated_block_timestamp(block_timestamp);
        (self.remaining_total_txn_num, self.remaining_total_proof_num) = self
            .proofs_for_consensus
            .num_total_txns_and_proofs(block_timestamp);
    }

    pub(crate) fn handle_proposal_request(&mut self, msg: GetPayloadCommand) {
        match msg {
            // TODO: check what max_txns consensus is using
            GetPayloadCommand::GetPayloadRequest(
                max_txns,
                max_bytes,
                return_non_full,
                filter,
                callback,
            ) => {
                // TODO: Pass along to batch_store
                let excluded_batches: HashSet<_> = match filter {
                    PayloadFilter::Empty => HashSet::new(),
                    PayloadFilter::DirectMempool(_) => {
                        unreachable!()
                    },
                    PayloadFilter::InQuorumStore(proofs) => proofs,
                };

                let proof_block = self.proofs_for_consensus.pull_proofs(
                    &excluded_batches,
                    max_txns,
                    max_bytes,
                    return_non_full,
                );

                let res = GetPayloadResponse::GetPayloadResponse(
                    if proof_block.is_empty() {
                        Payload::empty(true)
                    } else {
                        trace!(
                            "QS: GetBlockRequest excluded len {}, block len {}",
                            excluded_batches.len(),
                            proof_block.len()
                        );
                        Payload::InQuorumStore(ProofWithData::new(proof_block))
                    },
                );
                match callback.send(Ok(res)) {
                    Ok(_) => (),
                    Err(err) => debug!("BlockResponse receiver not available! error {:?}", err),
                }
            },
        }
    }

    /// return true when quorum store is back pressured
    pub(crate) fn qs_back_pressure(&self) -> BackPressure {
        BackPressure {
            txn_count: self.remaining_total_txn_num > self.back_pressure_total_txn_limit,
            proof_count: self.remaining_total_proof_num > self.back_pressure_total_proof_limit,
        }
    }

    pub async fn start(
        mut self,
        back_pressure_tx: tokio::sync::mpsc::Sender<BackPressure>,
        mut proposal_rx: Receiver<GetPayloadCommand>,
        mut proof_rx: tokio::sync::mpsc::Receiver<ProofManagerCommand>,
    ) {
        let mut back_pressure = BackPressure {
            txn_count: false,
            proof_count: false,
        };

        loop {
            // TODO: additional main loop counter
            let _timer = counters::WRAPPER_MAIN_LOOP.start_timer();

            tokio::select! {
                    Some(msg) = proposal_rx.next() => monitor!("proof_manager_handle_proposal", {
                        self.handle_proposal_request(msg);

                        let updated_back_pressure = self.qs_back_pressure();
                        if updated_back_pressure != back_pressure {
                            back_pressure = updated_back_pressure;
                            if back_pressure_tx.send(back_pressure).await.is_err() {
                                debug!("Failed to send back_pressure for proposal");
                            }
                        }
                    }),
                    Some(msg) = proof_rx.recv() => {
                        monitor!("proof_manager_handle_command", {
                        match msg {
                            ProofManagerCommand::Shutdown(ack_tx) => {
                                ack_tx
                                    .send(())
                                    .expect("Failed to send shutdown ack to QuorumStore");
                                break;
                            },
                            ProofManagerCommand::ReceiveProof(proof) => {
                                self.receive_proof(proof);
                            },
                            ProofManagerCommand::CommitNotification(block_timestamp, proofs) => {
                                self.handle_commit_notification(
                                    block_timestamp,
                                    proofs.iter().map(|proof| proof.info()).cloned().collect(),
                                );
                            },
                        }
                        let updated_back_pressure = self.qs_back_pressure();
                        if updated_back_pressure != back_pressure {
                            back_pressure = updated_back_pressure;
                            if back_pressure_tx.send(back_pressure).await.is_err() {
                                debug!("Failed to send back_pressure for commit notification");
                            }
                        }
                    })
                }
            }
        }
    }
}
