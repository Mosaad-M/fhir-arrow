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
  row until the end, peaking at roughly 3.6x the input size (952 MB for a
  261 MB Observation export). Use `ndjson_to_feather_streaming` for large
  inputs. Its peak is about 20 MB plus 5x the chunk size instead, and a
  single line longer than the chunk is still read whole.
- `fast_shred.mojo`'s byte scanner is intentionally narrow, not a general
  JSON parser.

## Benchmark

~3x to ~6x faster than Python (`json` + `pandas`/`pyarrow`) on a real
Synthea-generated Bulk FHIR export (`bench/gen_synthea_data.sh 500
Massachusetts`: 576 Patient / 250,116 Observation / 19,571 Condition
rows), 3 runs each: Patient 3.6 ms vs 20.8-21.1 ms, Observation 678-707
ms vs 2,148-2,160 ms, Condition 42-45 ms vs 146-150 ms. Output verified
identical: every column of all three tables, read back with `pyarrow`,
matches the Python baseline row for row, zero mismatches (including
`raw_json`).

### Memory and streaming

Peak RSS (`/usr/bin/time -l`) and wall time, macOS arm64, 3 runs each,
same export. Streaming output was checked against the whole-file output
with `pyarrow` (`Table.equals`) for all three resource types: identical.

| Input | Path | Peak RSS | Time |
|---|---|---|---|
| Observation, 261 MB | whole-file | 952 MB | 672-695 ms |
| Observation, 261 MB | streaming, 1 MiB chunks | 22 MB | 665-668 ms |
| Observation, 261 MB | streaming, 4 MiB chunks | 39-40 MB | 639-642 ms |
| Observation, 261 MB | streaming, 16 MiB chunks | 103 MB | 643-656 ms |
| Condition, 20 MB | whole-file | 85-108 MB | 46-47 ms |
| Condition, 20 MB | streaming, 1 MiB chunks | 19 MB | 43-44 ms |

Streaming memory tracks the chunk size, not the file size. The output
holds one RecordBatch per chunk (249 for the Observation file) where the
whole-file path writes one.

Whole-file Observation peaked at 2.1-2.4 GB before two fixes, both
leaving output byte-identical: arrow < 2.0 held several full copies of
each table while encoding (now one), and an unsized file read grew its
buffer to several times the file (now a sized read).

## Dependencies

- [arrow](https://github.com/Mosaad-M/arrow) `>=2.0.0`: pure-Mojo Arrow IPC
  encoder/decoder (pulls in `flatbuffers` transitively); `>=1.3.0` for
  `ArrowFileWriter`, which the streaming path writes through, and
  `>=2.0.0` for single-copy encoding and owned-buffer constructors

No `max` dependency: the parallel path is process-level, driven entirely
by the shell and this repo's own compiled binaries.

## License

MIT
