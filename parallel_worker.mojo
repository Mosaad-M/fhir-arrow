# parallel_worker.mojo: CLI entry point for one byte-range chunk of the
# parallel shredding pipeline.
#
# max.algorithm.parallelize's FuncType bound only accepts non-capturing
# (module-level) functions under the Mojo 1.1.0/max 26.6.0 toolchain this
# repo uses -- confirmed empirically (see tasks/lessons.md): nested `def`
# closures are always tagged "capturing" regardless of what they actually
# capture, `fn` was removed entirely (only `def` exists now), module-level
# mutable globals aren't supported, and dynamic values can't be bound as
# compile-time parameters, so there is no in-process way to hand a
# module-level worker function shared mutable state to write into. This
# repo's own 1brc_arrow, by contrast, is pinned to the older Mojo
# 1.0.0/max 26.5.0 toolchain where a capturing `@parameter def` closure
# still satisfied parallelize's FuncType -- that pattern is not available
# here without downgrading the whole repo's toolchain.
#
# So parallelism here is process-level, not in-process-thread-level: this
# binary reads ONLY its assigned [start_byte, end_byte) range directly from
# the ORIGINAL NDJSON file (via ndjson_range_to_feather -> read_ndjson_range,
# a seek+read, no whole-file read, no physical file copy) and writes its
# own Feather file. bench/run_parallel_mojo.sh runs chunk_planner ONCE to
# get newline-aligned byte boundaries, launches N copies of this compiled
# binary in parallel (one per chunk), waits for all of them, then runs
# merge_worker once to combine the N chunk Feather files into one.
#
# Two earlier, slower designs and why they were dropped (measured, not
# guessed -- see tasks/lessons.md for the full numbers):
#   1. Row-index range into the whole file (ndjson_range_to_feather's first
#      version): every worker called read_ndjson_lines on the WHOLE file to
#      compute the span list it would then slice, so 8 workers redundantly
#      paid the full-file read+scan cost. 8-worker Observation: 4748ms vs.
#      2132ms sequential -- parallel was slower.
#   2. Physically splitting the file with `split` first: correct, but
#      `split` has to copy the entire file's bytes to disk (Observation.ndjson
#      is 262MB), and merge_worker then re-reads all the chunk files -- for
#      this file size that I/O alone (~1s to split + ~1s to merge) is
#      comparable to the whole sequential baseline. 8-worker Observation:
#      2819ms vs. 2132ms sequential -- still slower, though much closer.
# The byte-range-via-seek design (this version) avoids both: one full-file
# read total (in chunk_planner), zero physical copies, each worker's cost
# scales with its own chunk size.
#
# Usage: parallel_worker <ndjson_path> <out_path> <kind> <start_byte> <end_byte>

from std.sys import argv
from fhir_arrow import ndjson_range_to_feather


def main() raises:
    var args = argv()
    if len(args) < 6:
        print("usage: parallel_worker <ndjson_path> <out_path> <kind> <start_byte> <end_byte>")
        return

    var ndjson_path = String(args[1])
    var out_path = String(args[2])
    var kind = String(args[3])
    var start_byte = Int(String(args[4]))
    var end_byte = Int(String(args[5]))

    ndjson_range_to_feather(ndjson_path, out_path, kind, start_byte, end_byte)
