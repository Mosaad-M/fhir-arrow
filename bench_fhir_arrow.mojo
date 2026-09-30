# bench_fhir_arrow.mojo: times ndjson_to_feather over a real Bulk FHIR
# NDJSON export (produced by bench/gen_synthea_data.sh).
#
# Usage: mojo run bench_fhir_arrow.mojo <synthea_fhir_dir> <out_dir> [max_chunk_bytes]
# Passing max_chunk_bytes times ndjson_to_feather_streaming instead.

from std.time import perf_counter_ns
from std.sys import argv
from fhir_arrow import ndjson_to_feather, ndjson_to_feather_streaming
from ndjson import read_ndjson_lines


def _run_one(
    label: String, ndjson_path: String, out_path: String, kind: String, max_chunk_bytes: Int
) raises:
    """Times ndjson_to_feather, or ndjson_to_feather_streaming when
    max_chunk_bytes > 0."""
    var t0 = perf_counter_ns()
    if max_chunk_bytes > 0:
        ndjson_to_feather_streaming(ndjson_path, out_path, kind, max_chunk_bytes)
    else:
        ndjson_to_feather(ndjson_path, out_path, kind)
    var elapsed_ns: Int = perf_counter_ns() - t0
    var elapsed_ms = Float64(elapsed_ns) / 1_000_000.0

    var result = read_ndjson_lines(ndjson_path)
    var n = len(result[1])
    var rows_per_sec = Float64(n) / (Float64(elapsed_ns) / 1_000_000_000.0)

    print(
        label
        + ": "
        + String(n)
        + " records in "
        + String(elapsed_ms)
        + " ms ("
        + String(rows_per_sec)
        + " rows/sec)"
    )


def main() raises:
    var args = argv()
    if len(args) < 3:
        print("usage: bench_fhir_arrow <synthea_fhir_dir> <out_dir> [max_chunk_bytes]")
        return

    var fhir_dir = String(args[1])
    var out_dir = String(args[2])
    var max_chunk_bytes = Int(String(args[3])) if len(args) >= 4 else 0

    _run_one(
        "Patient",
        fhir_dir + "/Patient.ndjson",
        out_dir + "/patients.feather",
        "Patient",
        max_chunk_bytes,
    )
    _run_one(
        "Observation",
        fhir_dir + "/Observation.ndjson",
        out_dir + "/observations.feather",
        "Observation",
        max_chunk_bytes,
    )
    _run_one(
        "Condition",
        fhir_dir + "/Condition.ndjson",
        out_dir + "/conditions.feather",
        "Condition",
        max_chunk_bytes,
    )
