# fhir-arrow: Bulk FHIR NDJSON to Apache Arrow (Feather), in pure Mojo

Shreds Bulk FHIR `$export` NDJSON files (Patient, Observation, Condition)
into columnar `.feather` files, using a hand-rolled zero-tree byte scanner
(no JSON tree is ever built) and a pure-Mojo Arrow IPC encoder. No Python,
no C dependencies.

## Quick start

```bash
pixi install                        # resolves arrow (git dep)
pixi run test-ndjson                # 17 tests
pixi run test-fast-shred            # 37 tests
pixi run test-fhir-arrow            # 38 tests
```

For the large-file (multi-core) path:

```bash
pixi run build-parallel-worker
pixi run build-merge-worker
pixi run build-chunk-planner
bench/run_parallel_mojo.sh <ndjson_path> <out_path> <Patient|Observation|Condition> [num_workers]
```

Only worth it above some file-size threshold -- the fixed per-process cost
doesn't pay for itself on small files, in either Mojo or Python.

```mojo
from fhir_arrow import ndjson_to_feather

ndjson_to_feather("patients.ndjson", "patients.feather", "Patient")
```

For exports that don't comfortably fit in memory, the streaming variant
takes the same arguments plus an optional chunk size (default 1 MiB) and
produces the same rows in bounded memory:

```mojo
from fhir_arrow import ndjson_to_feather_streaming

ndjson_to_feather_streaming("observations.ndjson", "observations.feather", "Observation")
```

```python
import pyarrow.feather as f
print(f.read_table("patients.feather"))
```

## Architecture

```
NDJSON file (one FHIR resource per line)
        |
        v
  read_ndjson_lines()    ndjson.mojo: reads the file once into one owned
        |                buffer and returns (content, spans), where spans
        |                are zero-copy (start, end) byte offsets into it.
        v
  Span[UInt8] per line (zero-copy slices of one buffer)
        |
        v
  shred_patient_fast_into_columns() / shred_observation_fast_into_columns()
  / shred_condition_fast_into_columns()
        |                fast_shred.mojo's scanning primitives decode
        |                ONLY the handful of known fields the schema
        |                cares about, writing decoded bytes DIRECTLY into
        |                the column builders below -- fused into the same
        |                scan, no intermediate row struct. Everything
        |                else is skipped in O(bytes) without allocating a
        |                representation for it. Only `id` is required.
        v
  PatientColumns / ObservationColumns / ConditionColumns
        |                fhir_arrow.mojo: StringColumnBuilder /
        |                BoolColumnBuilder / Float64ColumnBuilder, one per
        |                Arrow type. finish() assembles a RecordBatch,
        |                encoded via arrow.mojo's ArrowType/ArrowArray/
        |                encode_arrow_file API.
        v
  patients.feather / observations.feather / conditions.feather
```

One `.feather` file per resource type, matching how Bulk FHIR `$export`
itself splits output. `fast_shred.mojo`'s scanner is intentionally
narrow, not a general JSON parser: it's built to shred exactly the field
paths below correctly, not to handle arbitrary or malformed JSON
gracefully the way a general tree parser would.

## Field mapping

### Patient

| Column | FHIR path | Notes |
|---|---|---|
| `id` | `id` | required |
| `gender` | `gender` | |
| `birth_date` | `birthDate` | raw ISO string, not parsed to a date type |
| `family_name` | `name[0].family` | first `name` entry only |
| `given_name` | `name[0].given[0]` | first given name of the first entry only |
| `deceased` | `deceasedBoolean` | `deceasedDateTime` is out of scope, left null |
| `raw_json` | entire original resource | verbatim, not JSON-escape decoded |

### Observation

| Column | FHIR path | Notes |
|---|---|---|
| `id` | `id` | required |
| `patient_ref` | `subject.reference` | |
| `code` / `code_system` / `code_display` | `code.coding[0].{code,system,display}` | first coding only |
| `status` | `status` | |
| `effective_datetime` | `effectiveDateTime` | |
| `value_quantity` / `value_unit` | `valueQuantity.{value,unit}` | one of two `value[x]` variants handled |
| `value_string` | `valueString` | the other handled variant |
| `raw_json` | entire original resource | same as Patient's `raw_json` |

`value[x]` variants other than `valueQuantity`/`valueString` are out of
scope: both value columns are simply left null for that row.

### Condition

| Column | FHIR path | Notes |
|---|---|---|
| `id` | `id` | required |
| `patient_ref` | `subject.reference` | |
| `code` / `code_display` | `code.coding[0].{code,display}` | first coding only |
| `clinical_status` | `clinicalStatus.coding[0].code` | |
| `onset_datetime` | `onsetDateTime` | other `onset[x]` variants are out of scope |
| `recorded_date` | `recordedDate` | |
| `raw_json` | entire original resource | same as Patient's `raw_json` |

`raw_json` carries the complete, unmodified original resource JSON object
on every row, not escape-decoded, as a fallback for everything else this
schema doesn't shred (`meta`, `text`, `extension`, `identifier`,
`telecom`, `category`, `encounter`, `performer`, `referenceRange`, and
every other unmapped field). It roughly doubles wall-clock time per
resource type (see Known limitations) -- a real, non-free addition.

## Known limitations

- Only the fields listed above are individually shredded into typed
  columns; everything else is only available via the raw `raw_json`
  passthrough, and that passthrough has a real, measured cost (roughly
  doubles wall-clock time per resource type), not a free addition.
- `id` is the only field treated as required; every other field's absence
  is a null in that row, not an error.
- `ndjson_to_feather` loads the whole file into memory and holds every
  row until the end, peaking at roughly 8x the input size (2.1-2.3 GB for
  a 261 MB Observation export). Use `ndjson_to_feather_streaming` for
  large inputs. Its peak is about 20 MB plus 10x the chunk size instead,
  and a single line longer than the chunk is still read whole.
- `fast_shred.mojo`'s byte scanner is intentionally narrow, not a general
  JSON parser.

## Benchmark

~2.2x to ~4.4x faster than Python (`json` + `pandas`/`pyarrow`) across
Patient/Observation/Condition on a real Synthea-generated Bulk FHIR
export (Massachusetts, ~562 Patient / ~296,901 Observation / ~19,571
Condition rows), verified identical output field-by-field via real
`pyarrow.feather.read_table()`, including `raw_json` matching the source
NDJSON line byte-for-byte with zero mismatches across every row.
Regenerate the dataset with `bench/gen_synthea_data.sh 500 Massachusetts`.

### Streaming vs. whole-file (sequential)

Peak RSS (`/usr/bin/time -l`) and wall time, macOS arm64, 3 runs each, on
a fresh `gen_synthea_data.sh 500 Massachusetts` export (576 Patient /
250,116 Observation / 19,571 Condition rows). Streaming output was
checked against the whole-file output with `pyarrow` (`Table.equals`)
for all three resource types: identical.

| Input | Path | Peak RSS | Time |
|---|---|---|---|
| Observation, 261 MB | whole-file | 2.1-2.3 GB | 1.21-1.27 s |
| Observation, 261 MB | streaming, 1 MiB chunks | 29 MB | 975-983 ms |
| Observation, 261 MB | streaming, 4 MiB chunks | 72 MB | 964-968 ms |
| Observation, 261 MB | streaming, 16 MiB chunks | 177-178 MB | 976-984 ms |
| Condition, 20 MB | whole-file | 197 MB | 79-80 ms |
| Condition, 20 MB | streaming, 1 MiB chunks | 26 MB | 64-66 ms |
| Patient, 1.9 MB | whole-file | 28 MB | 6-7 ms |
| Patient, 1.9 MB | streaming, 1 MiB chunks | 21 MB | 5-6 ms |

Memory tracks the chunk size, not the file size. Streaming is also
slightly faster here, not slower. This hasn't been profiled; the much
smaller working set is the likely reason. The output holds one
RecordBatch per chunk (249 for the Observation file) where the
whole-file path writes one.

## Dependencies

- [arrow](https://github.com/Mosaad-M/arrow) `>=1.3.0`: pure-Mojo Arrow IPC
  encoder/decoder (pulls in `flatbuffers` transitively); `>=1.3.0` for
  `ArrowFileWriter`, which the streaming path writes through

No `max` dependency: the parallel path is process-level, driven entirely
by the shell and this repo's own compiled binaries.

## License

MIT
