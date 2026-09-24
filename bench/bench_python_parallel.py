#!/usr/bin/env python3
"""Parallel (multiprocessing) Python baseline for the fhir-arrow benchmark.

Companion to bench_python.py's single-threaded baseline. Exists specifically
for the phase D "parallel Mojo vs. parallel Python" comparison: per an
explicit user decision, when the Mojo side gets multi-core shredding, the
Python baseline gets multiprocessing too, so the benchmark stays apples to
apples at every stage instead of comparing parallel Mojo to single-threaded
Python. Reuses the exact same shredders as bench_python.py (imported, not
duplicated) -- only the execution strategy differs.

Usage: python3 bench_python_parallel.py <synthea_fhir_dir> <out_dir> [num_workers]
"""

import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor

import pandas as pd

from bench_python import SHREDDERS


def _process_chunk(args):
    """Runs in a worker process: read this chunk's lines, shred each one.
    Must be a module-level function (not a closure) to be picklable for
    ProcessPoolExecutor -- the same "no capturing state across the process
    boundary" constraint the Mojo side hit with max.algorithm.parallelize,
    just Python's own well-known version of it."""
    import json

    ndjson_path, kind, start_line, end_line = args
    shredder = SHREDDERS[kind]
    rows = []
    with open(ndjson_path, "r") as f:
        for i, line in enumerate(f):
            if i < start_line:
                continue
            if i >= end_line:
                break
            line = line.strip()
            if not line:
                continue
            rows.append(shredder(json.loads(line)))
    return rows


def run_one_parallel(label, ndjson_path, out_path, kind, num_workers):
    t0 = time.perf_counter()

    with open(ndjson_path, "r") as f:
        total_lines = sum(1 for _ in f)

    chunk_size = (total_lines + num_workers - 1) // num_workers
    chunks = []
    start = 0
    while start < total_lines:
        end = min(start + chunk_size, total_lines)
        chunks.append((ndjson_path, kind, start, end))
        start = end

    all_rows = []
    with ProcessPoolExecutor(max_workers=num_workers) as pool:
        for chunk_rows in pool.map(_process_chunk, chunks):
            all_rows.extend(chunk_rows)

    df = pd.DataFrame(all_rows)
    df.to_feather(out_path)

    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    n = len(all_rows)
    rows_per_sec = n / (elapsed_ms / 1000.0) if elapsed_ms > 0 else float("inf")
    print(f"{label}: {n} records in {elapsed_ms:.1f} ms ({rows_per_sec:.0f} rows/sec, {num_workers} workers)")


def main():
    if len(sys.argv) < 3:
        print("usage: bench_python_parallel.py <synthea_fhir_dir> <out_dir> [num_workers]")
        sys.exit(1)
    fhir_dir, out_dir = sys.argv[1], sys.argv[2]
    num_workers = int(sys.argv[3]) if len(sys.argv) > 3 else (os.cpu_count() or 4)

    run_one_parallel("Patient", f"{fhir_dir}/Patient.ndjson", f"{out_dir}/patients_py_par.feather", "Patient", num_workers)
    run_one_parallel("Observation", f"{fhir_dir}/Observation.ndjson", f"{out_dir}/observations_py_par.feather", "Observation", num_workers)
    run_one_parallel("Condition", f"{fhir_dir}/Condition.ndjson", f"{out_dir}/conditions_py_par.feather", "Condition", num_workers)


if __name__ == "__main__":
    main()
