#!/usr/bin/env python3

# Copyright © Aptos Foundation
# SPDX-License-Identifier: Apache-2.0

import subprocess
import re

# Set the tps and speedup ratio threshold for block size 1k, 10k and 50k
THRESHOLDS = {
    "1k_8": 15000,
    "1k_16": 19000,
    "1k_32": 20000,
    "10k_8": 27000,
    "10k_16": 46000,
    "10k_32": 63000,
    "50k_8": 29000,
    "50k_16": 53000,
    "50k_32": 82000,
}

SPEEDUPS = {
    "1k_8": 3,
    "1k_16": 4,
    "1k_32": 5,
    "10k_8": 6,
    "10k_16": 10,
    "10k_32": 13,
    "50k_8": 6,
    "50k_16": 11,
    "50k_32": 17,
}

THRESHOLDS_NOISE = 0.15
SPEEDUPS_NOISE_BELOW = 1
SPEEDUPS_NOISE_ABOVE = 2

THREADS = [(8, 1), (8, 2), (8, 8), (16, 1), (16, 4), (16, 16), (32, 1), (32, 4), (32, 8), (32, 32)]
BLOCK_SIZES = ["10k", "50k"]
target_directory = "aptos-move/aptos-transaction-benchmarks/src/"

tps_set = {}
speedups_set = {}

MAC = False

fail = False
for (threads, threads_per_counter) in THREADS:
    command = f"cargo run --profile performance main true true {threads} {threads_per_counter}"
    if not MAC:
        command = f"taskset -c 0-{threads-1} {command}" 
    output = subprocess.check_output(
        command, shell=True, text=True, cwd=target_directory
    )
    print(output)

    for i, block_size in enumerate(BLOCK_SIZES):
        tps_index = i * 2
        speedup_index = i * 2 + 1
        key = f"{block_size}_{threads}_{threads_per_counter}"
        tps = int(re.findall(r"Avg Parallel TPS = (\d+)", output)[i])
        speedups = int(re.findall(r"Speed up (\d+)x over sequential", output)[i])
        tps_set[key] = tps
        speedups_set[key] = speedups
        tps_diff = (tps - THRESHOLDS[key]) / THRESHOLDS[key]
        if abs(tps_diff) > THRESHOLDS_NOISE:
            print(
                f"Parallel TPS {tps} {'below' if tps_diff < 0 else 'above'} the threshold {THRESHOLDS[key]} by {abs(tps_diff)*100:.0f}% (more than {THRESHOLDS_NOISE*100:.0f}%). Please "
                f"{'optimize' if tps_diff < 0 else 'increase the hard-coded TPS threshold since you improved'} the execution performance. :)\n"
            )
            fail = True

        for speedup_threshold, noise, above in (
            (SPEEDUPS[key], SPEEDUPS_NOISE_BELOW, False),
            (SPEEDUPS[key], SPEEDUPS_NOISE_ABOVE, True),
        ):
            if abs((diff := speedups - speedup_threshold) / speedup_threshold) > noise:
                print(
                    f"Parallel SPEEDUPS {speedups} {'below' if not above else 'above'} the threshold {speedup_threshold} by {noise} for {block_size} block size with {threads} threads!  Please {'optimize' if not above else 'increase the hard-coded speedup threshold since you improved'} the execution performance. :)\n"
                )
                fail = True

for block_size in BLOCK_SIZES:
    for (threads, threads_per_counter) in THREADS:
        key = f"{block_size}_{threads}_{threads_per_counter}"
        print(
            f"Average Parallel TPS with {threads} threads and {threads_per_counter} per counter for {block_size} block: TPS {tps_set[key]}, Threshold TPS: {THRESHOLDS[key]}, Speedup: {speedups_set[key]}x, Speedup Threshold: {SPEEDUPS[key]}x"
        )

if fail:
    exit(1)
