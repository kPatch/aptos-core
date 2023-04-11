// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

use crate::{
    pruner::state_store::{generics::StaleNodeIndexSchemaTrait, StateMerklePruner},
    schema::{
        db_metadata::{DbMetadataSchema, DbMetadataValue},
        jellyfish_merkle_node::JellyfishMerkleNodeSchema,
    },
    utils::get_progress,
};
use anyhow::Result;
use aptos_jellyfish_merkle::StaleNodeIndex;
use aptos_schemadb::{schema::KeyCodec, SchemaBatch, DB};
use aptos_types::transaction::{AtomicVersion, Version};
use std::{
    cmp::max,
    marker::PhantomData,
    sync::{atomic::Ordering, Arc},
};

pub(in crate::pruner) struct StateMerkleMetadataPruner<S> {
    metadata_db: Arc<DB>,
    next_version: AtomicVersion,
    _phantom: PhantomData<S>,
}

impl<S: StaleNodeIndexSchemaTrait> StateMerkleMetadataPruner<S>
where
    StaleNodeIndex: KeyCodec<S>,
{
    pub(in crate::pruner) fn new(metadata_db: Arc<DB>) -> Self {
        Self {
            metadata_db,
            next_version: AtomicVersion::new(0),
            _phantom: PhantomData,
        }
    }

    pub(in crate::pruner) fn maybe_prune_single_version(
        &self,
        current_progress: Version,
        target_version: Version,
    ) -> Result<Option<Version>> {
        let next_version = self.next_version.load(Ordering::SeqCst);
        let target_version_for_this_round = max(next_version, current_progress);
        if target_version_for_this_round > target_version {
            return Ok(None);
        }

        let (indices, next_version) = StateMerklePruner::get_stale_node_indices(
            &self.metadata_db,
            current_progress,
            target_version_for_this_round,
            usize::max_value(),
        )?;

        let batch = SchemaBatch::new();
        indices.into_iter().try_for_each(|index| {
            batch.delete::<JellyfishMerkleNodeSchema>(&index.node_key)?;
            batch.delete::<S>(&index)
        })?;

        batch.put::<DbMetadataSchema>(
            &S::tag(None),
            &DbMetadataValue::Version(target_version_for_this_round),
        )?;

        self.metadata_db.write_schemas(batch)?;

        self.next_version.store(
            next_version.unwrap_or(target_version_for_this_round),
            Ordering::SeqCst,
        );

        Ok(Some(target_version_for_this_round))
    }

    pub(in crate::pruner) fn progress(&self) -> Result<Version> {
        Ok(get_progress(&self.metadata_db, &S::tag(None))?.unwrap_or(0))
    }
}
