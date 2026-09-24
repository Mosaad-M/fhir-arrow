# bench_fhir_arrow.mojo: times ndjson_to_feather over a real Bulk FHIR
# NDJSON export (produced by bench/gen_synthea_data.sh).
#
# Usage: mojo run bench_fhir_arrow.mojo <synthea_fhir_dir> <out_dir>

from std.time import perf_counter_ns
from std.sys import argv
from fhir_arrow import ndjson_to_feather
from ndjson import read_ndjson_lines


def _run_one(label: String, ndjson_path: String, out_path: String, kind: String) raises:
    var t0 = perf_counter_ns()
    ndjson_to_feather(ndjson_path, out_path, kind)
    var elapsed_ns: Int = perf_counter_ns() - t0
    var elapsed_ms = Float64(elapsed_ns) / 1_000_000.0

    var lines = read_ndjson_lines(ndjson_path)
    var n = len(lines)
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
        print("usage: bench_fhir_arrow <synthea_fhir_dir> <out_dir>")
        return

    var fhir_dir = String(args[1])
    var out_dir = String(args[2])

    _run_one(
        "Patient",
        fhir_dir + "/Patient.ndjson",
        out_dir + "/patients.feather",
        "Patient",
    )
    _run_one(
        "Observation",
        fhir_dir + "/Observation.ndjson",
        out_dir + "/observations.feather",
        "Observation",
    )
    _run_one(
        "Condition",
        fhir_dir + "/Condition.ndjson",
        out_dir + "/conditions.feather",
        "Condition",
    )
