// Copyright (c) Aptos
// SPDX-License-Identifier: Apache-2.0

//! Aptos is a one stop tool for operations, debugging, and other operations with the blockchain

#![forbid(unsafe_code)]

#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;
//static ALLOC: jemallocator::Jemalloc = jemallocator::Jemalloc;

use aptos::{move_tool, Tool};
use clap::Parser;
use std::process::exit;

#[tokio::main]
async fn main() {
    let profiler = dhat::Profiler::builder()
        .file_name("/tmp/profile.json")
        .build();

    // Register hooks
    move_tool::register_package_hooks();
    // Run the corresponding tools
    let result = Tool::parse().execute().await;

    // At this point, we'll want to print and determine whether to exit for an error code
    match result {
        Ok(inner) => println!("{}", inner),
        Err(inner) => {
            println!("{}", inner);
            drop(profiler);
            exit(1);
        }
    }
}
