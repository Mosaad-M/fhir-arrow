#!/usr/bin/env bash
# run_parallel_mojo.sh: process-level parallel benchmark driver.
#
# max.algorithm.parallelize's FuncType bound only accepts non-capturing
# (module-level) functions under this repo's Mojo 1.1.0/max 26.6.0
# toolchain (confirmed empirically -- see tasks/lessons.md and
# parallel_worker.mojo's header for the full story, including two earlier,
# slower designs this one replaced) -- there is no in-process way to hand a
# worker function shared mutable output state, so this uses OS-process
# parallelism instead, with zero-copy byte-range reads rather than a
# physical file split:
#
#   1. chunk_planner reads the file ONCE and prints newline-aligned
#      byte-range boundaries for N chunks.
#   2. N copies of parallel_worker run in parallel, each seeking directly
#      to its own byte range in the ORIGINAL file (no file copy, no
#      redundant whole-file read) and writing its own small Feather file.
#   3. merge_worker combines the N chunk Feather files into one, in order.
#
# Usage: run_parallel_mojo.sh <ndjson_path> <out_path> <kind> [num_workers]

set -euo pipefail

NDJSON_PATH="$1"
OUT_PATH="$2"
KIND="$3"
NUM_WORKERS="${4:-$(sysctl -n hw.physicalcpu 2>/dev/null || nproc)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

OUT_PATHS=()
PIDS=()
i=0
while read -r start_byte end_byte; do
  chunk_out="$TMP_DIR/chunk_${i}.feather"
  OUT_PATHS+=("$chunk_out")
  "$REPO_DIR/parallel_worker" "$NDJSON_PATH" "$chunk_out" "$KIND" "$start_byte" "$end_byte" &
  PIDS+=("$!")
  i=$((i + 1))
done < <("$REPO_DIR/chunk_planner" "$NDJSON_PATH" "$NUM_WORKERS")

for pid in "${PIDS[@]}"; do
  wait "$pid"
done

"$REPO_DIR/merge_worker" "$OUT_PATH" "${OUT_PATHS[@]}"
