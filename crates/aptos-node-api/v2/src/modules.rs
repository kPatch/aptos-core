// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

use async_graphql::Object;

#[derive(Clone, Debug)]
pub struct Module {
    address: String,
    name: String,
}

#[Object]
impl Module {
    async fn address(&self) -> &str {
        &self.address
    }

    async fn name(&self) -> &str {
        &self.name
    }
}
