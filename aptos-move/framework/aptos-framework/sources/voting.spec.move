spec aptos_framework::voting {
    spec module {
        pragma verify = true;
        pragma aborts_if_is_strict;
    }

    spec register<ProposalType: store>(account: &signer) {
        let addr = signer::address_of(account);

        // Will abort if there's already a `VotingForum<ProposalType>` under addr
        aborts_if exists<VotingForum<ProposalType>>(addr);
        // Creation of 4 new event handles changes the account's `guid_creation_num`
        aborts_if !exists<account::Account>(addr);
        let register_account = global<account::Account>(addr);
        aborts_if register_account.guid_creation_num + 4 >= account::MAX_GUID_CREATION_NUM;
        aborts_if register_account.guid_creation_num + 4 > MAX_U64;
        // `type_info::type_of()` may abort if the type parameter is not a struct
        aborts_if !type_info::spec_is_struct<ProposalType>();

        ensures exists<VotingForum<ProposalType>>(addr);
    }

    spec create_proposal<ProposalType: store>(
        proposer: address,
        voting_forum_address: address,
        execution_content: ProposalType,
        execution_hash: vector<u8>,
        min_vote_threshold: u128,
        expiration_secs: u64,
        early_resolution_vote_threshold: Option<u128>,
        metadata: SimpleMap<String, vector<u8>>,
    ): u64 {
        use aptos_framework::chain_status;

        requires chain_status::is_operating();
        include CreateProposalAbortsIf<ProposalType>{is_multi_step_proposal: false};
    }

    /// The min_vote_threshold lower thanearly_resolution_vote_threshold.
    /// Make sure the execution script's hash is not empty.
    /// VotingForum<ProposalType> existed under the voting_forum_address.
    /// The next_proposal_id in VotingForum is up to MAX_U64.
    /// CurrentTimeMicroseconds existed under the @aptos_framework.
    spec create_proposal_v2<ProposalType: store>(
        proposer: address,
        voting_forum_address: address,
        execution_content: ProposalType,
        execution_hash: vector<u8>,
        min_vote_threshold: u128,
        expiration_secs: u64,
        early_resolution_vote_threshold: Option<u128>,
        metadata: SimpleMap<String, vector<u8>>,
        is_multi_step_proposal: bool,
    ): u64 {
        use aptos_framework::chain_status;

        requires chain_status::is_operating();
        include CreateProposalAbortsIf<ProposalType>;
    }

    spec schema CreateProposalAbortsIf<ProposalType> {
        voting_forum_address: address;
        execution_hash: vector<u8>;
        min_vote_threshold: u128;
        early_resolution_vote_threshold: Option<u128>;
        metadata: SimpleMap<String, vector<u8>>;
        is_multi_step_proposal: bool;

        let voting_forum = global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal_id = voting_forum.next_proposal_id;

        aborts_if !exists<VotingForum<ProposalType>>(voting_forum_address);
        aborts_if table::spec_contains(voting_forum.proposals,proposal_id);
        aborts_if len(early_resolution_vote_threshold.vec) != 0 && min_vote_threshold > early_resolution_vote_threshold.vec[0];
        aborts_if !std::string::spec_internal_check_utf8(IS_MULTI_STEP_PROPOSAL_KEY);
        aborts_if !std::string::spec_internal_check_utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        aborts_if len(execution_hash) <= 0;
        let execution_key = std::string::spec_utf8(IS_MULTI_STEP_PROPOSAL_KEY);
        aborts_if simple_map::spec_contains_key(metadata,execution_key);
        aborts_if voting_forum.next_proposal_id + 1 > MAX_U64;
        let is_multi_step_in_execution_key = std::string::spec_utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        aborts_if is_multi_step_proposal && simple_map::spec_contains_key(metadata,is_multi_step_in_execution_key);
    }

    spec vote<ProposalType: store>(
        _proof: &ProposalType,
        voting_forum_address: address,
        proposal_id: u64,
        num_votes: u64,
        should_pass: bool,
    ) {
        use aptos_framework::chain_status;
        requires chain_status::is_operating(); // Ensures existence of Timestamp

        aborts_if !exists<VotingForum<ProposalType>>(voting_forum_address);
        let voting_forum = global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::spec_get(voting_forum.proposals, proposal_id);
        // Getting proposal from voting forum might fail because of non-exist id
        aborts_if !table::spec_contains(voting_forum.proposals, proposal_id);
        // Aborts when voting period is over or resolved
        aborts_if is_voting_period_over(proposal);
        aborts_if proposal.is_resolved;
        // Assert this proposal is single-step, or if the proposal is multi-step, it is not in execution yet.
        aborts_if !std::string::spec_internal_check_utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        let execution_key = std::string::spec_utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        aborts_if simple_map::spec_contains_key(proposal.metadata, execution_key) &&
                  simple_map::spec_get(proposal.metadata, execution_key) != std::bcs::serialize(false);
        aborts_if if (should_pass) { proposal.yes_votes + num_votes > MAX_U128 } else { proposal.no_votes + num_votes > MAX_U128 };

        aborts_if !std::string::spec_internal_check_utf8(RESOLVABLE_TIME_METADATA_KEY);
    }

    spec is_proposal_resolvable<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ) {

        use aptos_framework::chain_status;

        requires chain_status::is_operating(); // Ensures existence of Timestamp
        include AbortsIfNotContainProposalID<ProposalType>;
        // If the proposal is not resolvable, this function aborts.
        aborts_if spec_get_proposal_state<ProposalType>(voting_forum_address, proposal_id) != PROPOSAL_STATE_SUCCEEDED;

        let voting_forum =  global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::spec_get(voting_forum.proposals, proposal_id);

        aborts_if proposal.is_resolved;
        aborts_if !std::string::spec_internal_check_utf8(RESOLVABLE_TIME_METADATA_KEY);
        aborts_if !simple_map::spec_contains_key(proposal.metadata, std::string::spec_utf8(RESOLVABLE_TIME_METADATA_KEY));
        aborts_if !from_bcs::deserializable<u64>(simple_map::spec_get(proposal.metadata, std::string::spec_utf8(RESOLVABLE_TIME_METADATA_KEY)));
        aborts_if timestamp::spec_now_seconds() <= from_bcs::deserialize<u64>(simple_map::spec_get(proposal.metadata, std::string::spec_utf8(RESOLVABLE_TIME_METADATA_KEY)));
        aborts_if transaction_context::spec_get_script_hash() != proposal.execution_hash;
    }

    spec resolve<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): ProposalType {
        use aptos_framework::chain_status;
        requires chain_status::is_operating(); // Ensures existence of Timestamp

        pragma aborts_if_is_partial;
        include AbortsIfNotContainProposalID<ProposalType>;
        aborts_if !std::string::spec_internal_check_utf8(IS_MULTI_STEP_PROPOSAL_KEY);
    }

    spec resolve_proposal_v2<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
        next_execution_hash: vector<u8>,
    ) {
        use aptos_framework::chain_status;
        requires chain_status::is_operating(); // Ensures existence of Timestamp

        pragma aborts_if_is_partial;
        include AbortsIfNotContainProposalID<ProposalType>;
        aborts_if !std::string::spec_internal_check_utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        aborts_if !std::string::spec_internal_check_utf8(IS_MULTI_STEP_PROPOSAL_KEY);
    }

    spec next_proposal_id<ProposalType: store>(voting_forum_address: address): u64 {
        aborts_if !exists<VotingForum<ProposalType>>(voting_forum_address);
    }

    spec is_voting_closed<ProposalType: store>(voting_forum_address: address, proposal_id: u64): bool {
        use aptos_framework::chain_status;
        requires chain_status::is_operating(); // Ensures existence of Timestamp
        include AbortsIfNotContainProposalID<ProposalType>;
    }

    spec can_be_resolved_early<ProposalType: store>(proposal: &Proposal<ProposalType>): bool {
        aborts_if false;
    }

    spec fun spec_get_proposal_state<ProposalType>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64;

    spec get_proposal_state<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 {

        use aptos_framework::chain_status;
        pragma opaque;
        requires chain_status::is_operating(); // Ensures existence of Timestamp
        // Addition of yes_votes and no_votes might overflow.
        pragma addition_overflow_unchecked;

        include AbortsIfNotContainProposalID<ProposalType>;
        // Any way to specify the result?
        ensures [abstract] result == spec_get_proposal_state<ProposalType>(voting_forum_address, proposal_id);
    }

    spec get_proposal_creation_secs<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 {
        include AbortsIfNotContainProposalID<ProposalType>;
    }

    spec get_proposal_expiration_secs<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u64 {
        include AbortsIfNotContainProposalID<ProposalType>;
    }

    spec get_execution_hash<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): vector<u8> {
        include AbortsIfNotContainProposalID<ProposalType>;
    }

    spec get_min_vote_threshold<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): u128 {
        include AbortsIfNotContainProposalID<ProposalType>;
    }

    spec get_early_resolution_vote_threshold<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): Option<u128> {
        include AbortsIfNotContainProposalID<ProposalType>;
    }

    spec get_votes<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): (u128, u128) {
        include AbortsIfNotContainProposalID<ProposalType>;
    }

    spec is_resolved<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): bool {
        include AbortsIfNotContainProposalID<ProposalType>;
    }

    spec schema AbortsIfNotContainProposalID<ProposalType> {
        proposal_id: u64;
        voting_forum_address: address;
        let voting_forum = global<VotingForum<ProposalType>>(voting_forum_address);
        aborts_if !table::spec_contains(voting_forum.proposals, proposal_id);
        aborts_if !exists<VotingForum<ProposalType>>(voting_forum_address);
    }

    spec is_multi_step_proposal_in_execution<ProposalType: store>(
        voting_forum_address: address,
        proposal_id: u64,
    ): bool {
        let voting_forum = global<VotingForum<ProposalType>>(voting_forum_address);
        let proposal = table::spec_get(voting_forum.proposals,proposal_id);
        aborts_if !table::spec_contains(voting_forum.proposals,proposal_id);
        aborts_if !exists<VotingForum<ProposalType>>(voting_forum_address);
        aborts_if !std::string::spec_internal_check_utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);

        let execution_key = std::string::spec_utf8(IS_MULTI_STEP_PROPOSAL_IN_EXECUTION_KEY);
        aborts_if !simple_map::spec_contains_key(proposal.metadata,execution_key);

        let is_multi_step_in_execution_key = simple_map::spec_get(proposal.metadata,execution_key);
        aborts_if !aptos_std::from_bcs::deserializable<bool>(is_multi_step_in_execution_key);
    }

    spec is_voting_period_over<ProposalType: store>(proposal: &Proposal<ProposalType>): bool {
        use aptos_framework::chain_status;
        requires chain_status::is_operating();
        aborts_if false;
    }

}
