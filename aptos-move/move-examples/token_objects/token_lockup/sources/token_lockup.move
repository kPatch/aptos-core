module token_objects::token_lockup {
   use std::signer;
   use std::option;
   use std::error;
   use std::string::{Self, String};
   use std::object::{Self, Object, TransferRef, ConstructorRef};
   use std::timestamp;
   use aptos_token_objects::royalty::{Royalty};
   use aptos_token_objects::token::{Self, Token};
   use aptos_token_objects::collection;

   #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
   struct LockupConfig has key {
      last_transfer: u64,
      transfer_ref: TransferRef,
   }

   /// The owner of the token has not owned it for long enough.
   const ETOKEN_IN_LOCKUP: u64 = 0;
   /// The owner must own the token to transfer it
   const ENOT_TOKEN_OWNER: u64 = 1;

   const COLLECTION_NAME: vector<u8> = b"Rickety Raccoons";
   const COLLECTION_DESCRIPTION: vector<u8> = b"A collection of rickety raccoons!";
   const COLLECTION_URI: vector<u8> = b"https://ricketyracoonswebsite.com/collection/rickety-raccoon.png";
   const TOKEN_URI: vector<u8> = b"https://ricketyracoonswebsite.com/tokens/raccoon.png";
   const MAXIMUM_SUPPLY: u64 = 1000;
   // 24 hours in one day * 60 minutes in one hour * 60 seconds in one minute
   const SECONDS_PER_DAY: u64 = 24 * 60 * 60;
   const LOCKUP_PERIOD_DAYS: u64 = 7;

   public fun initialize_collection(creator: &signer) {
      collection::create_fixed_collection(
         creator,
         string::utf8(COLLECTION_DESCRIPTION),
         MAXIMUM_SUPPLY,
         string::utf8(COLLECTION_NAME),
         option::none<Royalty>(),
         string::utf8(COLLECTION_URI),
      );
   }

   public fun mint_to(
      creator: &signer,
      token_name: String,
      to: address,
   ): ConstructorRef {
      let token_constructor_ref = token::create_named_token(
         creator,
         string::utf8(COLLECTION_NAME),
         string::utf8(COLLECTION_DESCRIPTION),
         token_name,
         option::none(),
         string::utf8(TOKEN_URI),
      );

      let transfer_ref = object::generate_transfer_ref(&token_constructor_ref);
      let token_signer = object::generate_signer(&token_constructor_ref);
      let token_object = object::object_from_constructor_ref<Token>(&token_constructor_ref);

      // transfer the token to the receiving account before we permanently disable ungated transfer
      object::transfer(creator, token_object, to);

      // disable the ability to transfer the token through any means other than the `transfer` function we define
      object::disable_ungated_transfer(&transfer_ref);

      move_to(
         &token_signer,
         LockupConfig {
            last_transfer: timestamp::now_seconds(),
            transfer_ref,
         }
      );

      token_constructor_ref
   }

   public entry fun transfer(
      from: &signer,
      token: Object<Token>,
      to: address,
   ) acquires LockupConfig {
      // redundant error checking for clear error message
      assert!(object::is_owner(token, signer::address_of(from)), error::permission_denied(ENOT_TOKEN_OWNER));
      let lockup_config = borrow_global_mut<LockupConfig>(object::object_address(&token));
      
      let time_since_transfer = timestamp::now_seconds() - lockup_config.last_transfer;
      let lockup_period_secs = LOCKUP_PERIOD_DAYS * SECONDS_PER_DAY;
      assert!(time_since_transfer >= lockup_period_secs, error::permission_denied(ETOKEN_IN_LOCKUP));

      // generate linear transfer ref and transfer the token object
      let linear_transfer_ref = object::generate_linear_transfer_ref(&lockup_config.transfer_ref);
      object::transfer_with_ref(linear_transfer_ref, to);

      // update the lockup config to reflect the latest transfer time
      *&mut lockup_config.last_transfer = timestamp::now_seconds();
   }

   #[view]
   public fun view_last_transfer(
      token: Object<Token>,
   ): u64 acquires LockupConfig {
      borrow_global<LockupConfig>(object::object_address(&token)).last_transfer
   }

   #[test_only]
   const TEST_START_TIME: u64 = 1000000000;
   #[test_only]
   use aptos_framework::account;


   #[test_only]
   fun setup_test(
       creator: &signer,
       owner_1: &signer,
       owner_2: &signer,
       aptos_framework: &signer,
       start_time: u64,
   ) {
         timestamp::set_time_has_started_for_testing(aptos_framework);
         timestamp::update_global_time_for_test_secs(start_time);
         account::create_account_for_test(signer::address_of(creator));
         account::create_account_for_test(signer::address_of(owner_1));
         account::create_account_for_test(signer::address_of(owner_2));
         initialize_collection(creator);
   }

   #[test_only]
   fun fast_forward_secs(seconds: u64) {
      timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + seconds);
   }

   #[test (creator = @0xFA, owner_1 = @0xA, owner_2 = @0xB, aptos_framework = @0x1)]
   /// tests transferring multiple tokens to and from multiple different owners with slightly different initial lockup times
   fun test_happy_path(
      creator: &signer,
      owner_1: &signer,
      owner_2: &signer,
      aptos_framework: &signer,
   ) acquires LockupConfig {
      setup_test(
         creator,
         owner_1,
         owner_2,
         aptos_framework,
         TEST_START_TIME
      );
      
      let owner_1_addr = signer::address_of(owner_1);
      let owner_2_addr = signer::address_of(owner_2);

      // mint 1 token to each of the 2 owner accounts
      let token_1_constructor_ref = mint_to(creator, string::utf8(b"Token #1"), owner_1_addr);
      let token_2_constructor_ref = mint_to(creator, string::utf8(b"Token #2"), owner_2_addr);
      // mint 1 more token to owner_1 one second later
      fast_forward_secs(1);
      let token_3_constructor_ref = mint_to(creator, string::utf8(b"Token #3"), owner_1_addr);

      let token_1_obj = object::object_from_constructor_ref(&token_1_constructor_ref);
      let token_2_obj = object::object_from_constructor_ref(&token_2_constructor_ref);
      let token_3_obj = object::object_from_constructor_ref(&token_3_constructor_ref);

      // fast forward global time by 1 week - 1 second
      fast_forward_secs((LOCKUP_PERIOD_DAYS * SECONDS_PER_DAY) - 1);

      // ensures that the `last_transfer` for each token is correct
      assert!(view_last_transfer(token_1_obj) == TEST_START_TIME, 0);
      assert!(view_last_transfer(token_2_obj) == TEST_START_TIME, 1);
      assert!(view_last_transfer(token_3_obj) == TEST_START_TIME + 1, 2);


      // transfer the first token from owner_1 to owner_2
      transfer(owner_1, token_1_obj, owner_2_addr);
      // transfer the second token from owner_2 to owner_1
      transfer(owner_2, token_2_obj, owner_1_addr);
      // fast forward global time by 1 second
      fast_forward_secs(1);
      // transfer the third token from owner_1 to owner_2
      transfer(owner_1, token_3_obj, owner_2_addr);
      // ensures that the `last_transfer` for each token is correct
      assert!(view_last_transfer(token_1_obj) == TEST_START_TIME + (LOCKUP_PERIOD_DAYS * SECONDS_PER_DAY), 3);
      assert!(view_last_transfer(token_2_obj) == TEST_START_TIME + (LOCKUP_PERIOD_DAYS * SECONDS_PER_DAY), 4);
      assert!(view_last_transfer(token_3_obj) == TEST_START_TIME + (LOCKUP_PERIOD_DAYS * SECONDS_PER_DAY) + 1, 5);

      // ensures that the owners respectively are owner_2, owner_1, and owner_2
      assert!(object::is_owner(token_1_obj, owner_2_addr), 6);
      assert!(object::is_owner(token_2_obj, owner_1_addr), 7);
      assert!(object::is_owner(token_3_obj, owner_2_addr), 8);
   }

   #[test (creator = @0xFA, owner_1 = @0xA, owner_2 = @0xB, aptos_framework = @0x1)]
   #[expected_failure(abort_code = 0x50003, location = aptos_framework::object)]
   fun transfer_raw_fail(
      creator: &signer,
      owner_1: &signer,
      owner_2: &signer,
      aptos_framework: &signer,
   ) {
      setup_test(
         creator,
         owner_1,
         owner_2,
         aptos_framework,
         TEST_START_TIME
      );

      let token_1_constructor_ref = mint_to(creator, string::utf8(b"Token #1"), signer::address_of(owner_1));
      object::transfer_raw(
         owner_1,
         object::address_from_constructor_ref(&token_1_constructor_ref),
         signer::address_of(owner_2)
      );
   }

   #[test (creator = @0xFA, owner_1 = @0xA, owner_2 = @0xB, aptos_framework = @0x1)]
   #[expected_failure(abort_code = 0x50000, location = token_objects::token_lockup)]
   fun transfer_too_early(
      creator: &signer,
      owner_1: &signer,
      owner_2: &signer,
      aptos_framework: &signer,
   ) acquires LockupConfig {
      setup_test(
         creator,
         owner_1,
         owner_2,
         aptos_framework,
         TEST_START_TIME
      );

      let token_1_constructor_ref = mint_to(creator, string::utf8(b"Token #1"), signer::address_of(owner_1));
      let token_1_obj = object::object_from_constructor_ref(&token_1_constructor_ref);

      // one second too early
      fast_forward_secs((LOCKUP_PERIOD_DAYS * SECONDS_PER_DAY) - 1);
      transfer(owner_1, token_1_obj, signer::address_of(owner_2));
   }

   #[test (creator = @0xFA, owner_1 = @0xA, owner_2 = @0xB, aptos_framework = @0x1)]
   #[expected_failure(abort_code = 0x50001, location = token_objects::token_lockup)]
   fun transfer_wrong_owner(
      creator: &signer,
      owner_1: &signer,
      owner_2: &signer,
      aptos_framework: &signer,
   ) acquires LockupConfig {
      setup_test(
         creator,
         owner_1,
         owner_2,
         aptos_framework,
         TEST_START_TIME
      );

      let token_1_constructor_ref = mint_to(creator, string::utf8(b"Token #1"), signer::address_of(owner_1));
      let token_1_obj = object::object_from_constructor_ref<Token>(&token_1_constructor_ref);

      fast_forward_secs(LOCKUP_PERIOD_DAYS * SECONDS_PER_DAY);
      transfer(owner_2, token_1_obj, signer::address_of(owner_1));
   }
}