/// This module provides an interface to burn or collect and redistribute transaction fees.
module aptos_framework::transaction_fee {
    use aptos_framework::coin::{Self, AggregatableCoin, BurnCapability};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::stake;
    use aptos_framework::system_addresses;
    use std::error;
    use std::option::{Self, Option};
    use std::vector;

    friend aptos_framework::block;
    friend aptos_framework::genesis;
    friend aptos_framework::reconfiguration;
    friend aptos_framework::transaction_validation;

    /// Transaction fees are already being collected and the struct holding
    /// information about collected amounts is already published.
    const EALREADY_COLLECTING_FEES: u64 = 1;

    /// Trying to register more batch proposers than the number of aggregatable
    /// coins in the system. 
    const ETOO_MANY_BATCH_PROPOSERS: u64 = 2;

    /// Percentage is out of range [0, 100].
    const EINVALID_PERCENTAGE: u64 = 3;

    /// Stores burn capability to burn the gas fees.
    struct AptosCoinCapabilities has key {
        burn_cap: BurnCapability<AptosCoin>,
    }

    /// Stores information about the block proposer and the amount of fees
    /// collected when executing the block.
    struct CollectedFeesPerBlockAndBatches has key {
        block_proposer: Option<address>,
        max_num_batch_proposers: u16,
        batch_proposers: vector<address>,
        amounts: vector<AggregatableCoin<AptosCoin>>,
        block_distribution_percentage: u8,
        batch_distribution_percentage: u8,
    }

    /// Initializes the resource storing information about gas fees collection and
    /// distribution. Should be called by on-chain governance.
    public fun initialize_fee_collection_and_distributions(aptos_framework: &signer, max_num_batch_proposers: u16, block_distribution_percentage: u8, batch_distribution_percentage: u8) {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert!(
            !exists<CollectedFeesPerBlockAndBatches>(@aptos_framework),
            error::already_exists(EALREADY_COLLECTING_FEES)
        );
        assert!(block_distribution_percentage + batch_distribution_percentage <= 100, error::out_of_range(EINVALID_PERCENTAGE));

        // Make sure stakng module is aware of transaction fees collection.
        stake::initialize_validator_fees(aptos_framework);

        // All aggregators are pre-initialized in order to avoid creating/deleting more table items.
        let i = 0;
        let amounts = vector::empty();
        while (i < max_num_batch_proposers) {
            let amount = coin::initialize_aggregatable_coin(aptos_framework);
            vector::push_back(&mut amounts, amount);
            i = i + 1;
        };

        // Initially, no fees are collected, so the block proposer is not set.
        let collected_fees = CollectedFeesPerBlockAndBatches {
            block_proposer: option::none(),
            max_num_batch_proposers,
            batch_proposers: vector::empty(),
            amounts,
            block_distribution_percentage,
            batch_distribution_percentage,
        };
        move_to(aptos_framework, collected_fees);
    }

    fun is_fees_collection_enabled(): bool {
        exists<CollectedFeesPerBlockAndBatches>(@aptos_framework)
    }

    /// Sets the burn percentage for collected fees to a new value. Should be called by on-chain governance.
    public fun upgrade_distribution_percentages(
        aptos_framework: &signer,
        new_block_distribution_percentage: u8,
        new_batch_distribution_percentage: u8
    ) acquires CollectedFeesPerBlockAndBatches, AptosCoinCapabilities {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert!(new_block_distribution_percentage + new_batch_distribution_percentage <= 100, error::out_of_range(EINVALID_PERCENTAGE));

        // Upgrade has no effect unless fees are being collected.
        if (is_fees_collection_enabled()) {
            // We must process all the fees before upgrading the distribution
            // percentages. Otherwise new percentages will be used to distribute
            // fees for this block.
            process_collected_fees();
            
            let config = borrow_global_mut<CollectedFeesPerBlockAndBatches>(@aptos_framework);
            config.block_distribution_percentage = new_block_distribution_percentage;
            config.batch_distribution_percentage = new_batch_distribution_percentage;
        }
    }

    /// Registers new block and batch proposers to collect transaction fees.
    /// This function should only be called at the beginning of the block.
    public(friend) fun register_proposers_for_fee_collection(
        block_proposer_addr: address,
        batch_proposers_addr: vector<address>
    ) acquires CollectedFeesPerBlockAndBatches {
        if (is_fees_collection_enabled()) {
            let config = borrow_global_mut<CollectedFeesPerBlockAndBatches>(@aptos_framework);
            assert!(vector::length(&batch_proposers_addr) <= (config.max_num_batch_proposers as u64), error::invalid_argument(ETOO_MANY_BATCH_PROPOSERS));
            
            let _ = option::swap_or_fill(&mut config.block_proposer, block_proposer_addr);
            let batch_proposers = &mut config.batch_proposers;
            *batch_proposers = batch_proposers_addr;
        }
    }

    /// Calculates the fee which should be distributed to block/batch proposers at the
    /// end of an epoch, and records it in the system. This function should only be called
    /// at the beginning of the block or during reconfiguration.
    public(friend) fun process_collected_fees() acquires CollectedFeesPerBlockAndBatches, AptosCoinCapabilities {
        if (!is_fees_collection_enabled()) {
            return
        };
        let config = borrow_global_mut<CollectedFeesPerBlockAndBatches>(@aptos_framework);

        // All collected fees are burnt if the block proposer is not set or when
        // the block is proposed by the VM.
        let burn_all = option::is_none(&config.block_proposer) || (option::is_some(&config.block_proposer) && *option::borrow(&config.block_proposer) == @vm_reserved);

        let i = 0;
        let undistributed_coin = coin::zero<AptosCoin>();
        let num_batch_proposers = vector::length(&config.batch_proposers);
        while (i < num_batch_proposers) {
            // First, get the collected amount and check if we can avoid calculations.
            let aggregatable_coin = vector::borrow_mut(&mut config.amounts, i);
            if (coin::is_aggregatable_coin_zero(aggregatable_coin)) {
                i = i + 1;
                continue
            };
            let coin = coin::drain_aggregatable_coin(aggregatable_coin);

            if (burn_all) {
                coin::burn(
                    coin,
                    &borrow_global<AptosCoinCapabilities>(@aptos_framework).burn_cap,
                );
                i = i + 1;
                continue
            };

            // Otherwise, some portion of fees has to go to the batch proposer
            // and the remaining amount is accumulated for later use.
            let batch_proposer_addr = *vector::borrow(&config.batch_proposers, i);
            let amount_for_batch_proposer = (config.batch_distribution_percentage as u64) * coin::value(&coin) / 100;
            if (amount_for_batch_proposer > 0) {
                stake::add_transaction_fee(batch_proposer_addr, coin::extract(&mut coin, amount_for_batch_proposer));
            };
            coin::merge(&mut undistributed_coin, coin);
            i = i + 1;
        };

        if (burn_all || coin::value(&undistributed_coin) == 0) {
            coin::destroy_zero(undistributed_coin);
            // Also unset the proposer. See the rationale for setting proposer
            // to option::none() below.
            if (option::is_some(&config.block_proposer)) {
                let _ = option::extract(&mut config.block_proposer);
            };
            return
        };

        // Extract the address of proposer here and reset it to option::none(). This
        // is particularly useful to avoid any undesired side-effects where coins are
        // collected but never distributed or distributed to the wrong account.
        // With this design, processing collected fees enforces that all fees will be burnt
        // unless the block proposer is specified in the block prologue. When we have a governance
        // proposal that triggers reconfiguration, we distribute pending fees and burn the
        // fee for the proposal. Otherwise, that fee would be leaked to the next block.
        let block_proposer_addr = option::extract(&mut config.block_proposer);
        let amount_for_block_proposer = (config.block_distribution_percentage as u64) * coin::value(&undistributed_coin) / 100;
        if (amount_for_block_proposer > 0) {
            stake::add_transaction_fee(block_proposer_addr, coin::extract(&mut undistributed_coin, amount_for_block_proposer));
        };

        coin::burn(
            undistributed_coin,
            &borrow_global<AptosCoinCapabilities>(@aptos_framework).burn_cap,
        );
    }

    /// Burn transaction fees in epilogue.
    public(friend) fun burn_fee(account: address, fee: u64) acquires AptosCoinCapabilities {
        coin::burn_from<AptosCoin>(
            account,
            fee,
            &borrow_global<AptosCoinCapabilities>(@aptos_framework).burn_cap,
        );
    }

    /// Collect transaction fees in epilogue.
    public(friend) fun collect_fee_for_batch(account: address, fee: u64, batch_index: u16) acquires CollectedFeesPerBlockAndBatches {
        let config = borrow_global_mut<CollectedFeesPerBlockAndBatches>(@aptos_framework);

        // Here, we are always optimistic and always collect fees. If the proposer is not set,
        // or we cannot redistribute fees later for some reason (e.g. account cannot receive AptoCoin)
        // we burn them all at once. This way we avoid having a check for every transaction epilogue.
        let aggregatable_coin = vector::borrow_mut(&mut config.amounts, (batch_index as u64));
        coin::collect_into_aggregatable_coin<AptosCoin>(account, fee, aggregatable_coin);
    }

    /// Only called during genesis.
    public(friend) fun store_aptos_coin_burn_cap(aptos_framework: &signer, burn_cap: BurnCapability<AptosCoin>) {
        system_addresses::assert_aptos_framework(aptos_framework);
        move_to(aptos_framework, AptosCoinCapabilities { burn_cap })
    }

    // #[test_only]
    // use aptos_framework::aggregator_factory;

    // #[test(aptos_framework = @aptos_framework)]
    // fun test_initialize_fee_collection_and_distribution(aptos_framework: signer) acquires CollectedFeesPerBlockAndBatches {
    //     aggregator_factory::initialize_aggregator_factory_for_test(&aptos_framework);
    //     initialize_fee_collection_and_distributions(&aptos_framework, 10, 65);

    //     // Check struct has been published.
    //     assert!(exists<CollectedFeesPerBlockAndBatches>(@aptos_framework), 0);

    //     // Check that initial balance is 0 and there is no proposer set.
    //     let collected_fees = borrow_global<CollectedFeesPerBlockAndBatches>(@aptos_framework);
    //     assert!(coin::is_aggregatable_coin_zero(&collected_fees.amount), 0);
    //     assert!(option::is_none(&collected_fees.proposer), 0);
    //     assert!(collected_fees.burn_percentage == 25, 0);
    // }

    // #[test(aptos_framework = @aptos_framework)]
    // fun test_burn_fraction_calculation(aptos_framework: signer) acquires AptosCoinCapabilities {
    //     use aptos_framework::aptos_coin;
    //     let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);
    //     store_aptos_coin_burn_cap(&aptos_framework, burn_cap);

    //     let c1 = coin::mint<AptosCoin>(100, &mint_cap);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 100, 0);

    //     // Burning 25%.
    //     burn_coin_fraction(&mut c1, 25);
    //     assert!(coin::value(&c1) == 75, 0);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 75, 0);

    //     // Burning 0%.
    //     burn_coin_fraction(&mut c1, 0);
    //     assert!(coin::value(&c1) == 75, 0);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 75, 0);

    //     // Burning remaining 100%.
    //     burn_coin_fraction(&mut c1, 100);
    //     assert!(coin::value(&c1) == 0, 0);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 0, 0);

    //     coin::destroy_zero(c1);
    //     let c2 = coin::mint<AptosCoin>(10, &mint_cap);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 10, 0);

    //     burn_coin_fraction(&mut c2, 5);
    //     assert!(coin::value(&c2) == 10, 0);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 10, 0);

    //     burn_coin_fraction(&mut c2, 100);
    //     coin::destroy_zero(c2);
    //     coin::destroy_burn_cap(burn_cap);
    //     coin::destroy_mint_cap(mint_cap);
    // }

    // #[test(aptos_framework = @aptos_framework, alice = @0xa11ce, bob = @0xb0b, carol = @0xca101)]
    // fun test_fees_distribution(
    //     aptos_framework: signer,
    //     alice: signer,
    //     bob: signer,
    //     carol: signer,
    // ) acquires AptosCoinCapabilities, CollectedFeesPerBlockAndBatches {
    //     use std::signer;
    //     use aptos_framework::aptos_account;
    //     use aptos_framework::aptos_coin;

    //     // Initialization.
    //     let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&aptos_framework);
    //     store_aptos_coin_burn_cap(&aptos_framework, burn_cap);
    //     initialize_fee_collection_and_distributions(&aptos_framework, 10, 80);

    //     // Create dummy accounts.
    //     let alice_addr = signer::address_of(&alice);
    //     let bob_addr = signer::address_of(&bob);
    //     let carol_addr = signer::address_of(&carol);
    //     aptos_account::create_account(alice_addr);
    //     aptos_account::create_account(bob_addr);
    //     aptos_account::create_account(carol_addr);
    //     coin::deposit(alice_addr, coin::mint(10000, &mint_cap));
    //     coin::deposit(bob_addr, coin::mint(10000, &mint_cap));
    //     coin::deposit(carol_addr, coin::mint(10000, &mint_cap));
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 30000, 0);

    //     // Block 1 starts.
    //     process_collected_fees();
    //     register_proposer_for_fee_collection(alice_addr);

    //     // Check that there was no fees distribution in the first block.
    //     let collected_fees = borrow_global<CollectedFeesPerBlockAndBatches>(@aptos_framework);
    //     assert!(coin::is_aggregatable_coin_zero(&collected_fees.amount), 0);
    //     assert!(*option::borrow(&collected_fees.proposer) == alice_addr, 0);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 30000, 0);

    //     // Simulate transaction fee collection - here we simply collect some fees from Bob.
    //     collect_fee(bob_addr, 100);
    //     collect_fee(bob_addr, 500);
    //     collect_fee(bob_addr, 400);

    //     // Now Bob must have 1000 less in his account. Alice and Carol have the same amounts.
    //     assert!(coin::balance<AptosCoin>(alice_addr) == 10000, 0);
    //     assert!(coin::balance<AptosCoin>(bob_addr) == 9000, 0);
    //     assert!(coin::balance<AptosCoin>(carol_addr) == 10000, 0);

    //     // Block 2 starts.
    //     process_collected_fees();
    //     register_proposer_for_fee_collection(bob_addr);

    //     // Collected fees from Bob must have been assigned to Alice.
    //     assert!(stake::get_validator_fee(alice_addr) == 900, 0);
    //     assert!(coin::balance<AptosCoin>(alice_addr) == 10000, 0);
    //     assert!(coin::balance<AptosCoin>(bob_addr) == 9000, 0);
    //     assert!(coin::balance<AptosCoin>(carol_addr) == 10000, 0);

    //     // Also, aggregator coin is drained and total supply is slightly changed (10% of 1000 is burnt).
    //     let collected_fees = borrow_global<CollectedFeesPerBlockAndBatches>(@aptos_framework);
    //     assert!(coin::is_aggregatable_coin_zero(&collected_fees.amount), 0);
    //     assert!(*option::borrow(&collected_fees.proposer) == bob_addr, 0);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 29900, 0);

    //     // Simulate transaction fee collection one more time.
    //     collect_fee(bob_addr, 5000);
    //     collect_fee(bob_addr, 4000);

    //     assert!(coin::balance<AptosCoin>(alice_addr) == 10000, 0);
    //     assert!(coin::balance<AptosCoin>(bob_addr) == 0, 0);
    //     assert!(coin::balance<AptosCoin>(carol_addr) == 10000, 0);

    //     // Block 3 starts.
    //     process_collected_fees();
    //     register_proposer_for_fee_collection(carol_addr);

    //     // Collected fees should have been assigned to Bob because he was the peoposer.
    //     assert!(stake::get_validator_fee(alice_addr) == 900, 0);
    //     assert!(coin::balance<AptosCoin>(alice_addr) == 10000, 0);
    //     assert!(stake::get_validator_fee(bob_addr) == 8100, 0);
    //     assert!(coin::balance<AptosCoin>(bob_addr) == 0, 0);
    //     assert!(coin::balance<AptosCoin>(carol_addr) == 10000, 0);

    //     // Again, aggregator coin is drained and total supply is changed by 10% of 9000.
    //     let collected_fees = borrow_global<CollectedFeesPerBlockAndBatches>(@aptos_framework);
    //     assert!(coin::is_aggregatable_coin_zero(&collected_fees.amount), 0);
    //     assert!(*option::borrow(&collected_fees.proposer) == carol_addr, 0);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 29000, 0);

    //     // Simulate transaction fee collection one last time.
    //     collect_fee(alice_addr, 1000);
    //     collect_fee(alice_addr, 1000);

    //     // Block 4 starts.
    //     process_collected_fees();
    //     register_proposer_for_fee_collection(alice_addr);

    //     // Check that 2000 was collected from Alice.
    //     assert!(coin::balance<AptosCoin>(alice_addr) == 8000, 0);
    //     assert!(coin::balance<AptosCoin>(bob_addr) == 0, 0);

    //     // Carol must have some fees assigned now.
    //     let collected_fees = borrow_global<CollectedFeesPerBlockAndBatches>(@aptos_framework);
    //     assert!(stake::get_validator_fee(carol_addr) == 1800, 0);
    //     assert!(coin::is_aggregatable_coin_zero(&collected_fees.amount), 0);
    //     assert!(*option::borrow(&collected_fees.proposer) == alice_addr, 0);
    //     assert!(*option::borrow(&coin::supply<AptosCoin>()) == 28800, 0);

    //     coin::destroy_burn_cap(burn_cap);
    //     coin::destroy_mint_cap(mint_cap);
    // }


    // OLD: keeping for backward compatibility.

    /// Stores information about the block proposer and the amount of fees
    /// collected when executing the block.
    struct CollectedFeesPerBlock has key {
        amount: AggregatableCoin<AptosCoin>,
        proposer: Option<address>,
        burn_percentage: u8,
    }

    public fun initialize_fee_collection_and_distribution(_aptos_framework: &signer, _burn_percentage: u8) {
    }

    public fun upgrade_burn_percentage(
        _aptos_framework: &signer,
        _new_burn_percentage: u8
    ) {
    }

    public(friend) fun register_proposer_for_fee_collection(_proposer_addr: address) {
    }

    public(friend) fun collect_fee(_account: address, _fee: u64) {
    }
}
