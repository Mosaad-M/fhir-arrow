# fhir-arrow: Bulk FHIR NDJSON to Apache Arrow (Feather), in pure Mojo

Shreds Bulk FHIR `$export` NDJSON files (Patient, Observation, Condition)
into columnar `.feather` files, using a hand-rolled zero-tree byte scanner
(no JSON tree is ever built) and a pure-Mojo Arrow IPC encoder. No Python,
no C dependencies.

## Quick start

```bash
pixi install                        # resolves arrow (git dep)
pixi run test-ndjson                # 13 tests
pixi run test-fast-shred            # 37 tests
pixi run test-fhir-arrow            # 34 tests
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
- No streaming on the sequential path: `read_ndjson_lines` loads the
  whole file into memory as one `String` before shredding (lines are then
  zero-copy byte spans into it, not separate allocations, but the whole
  file is still resident at once). The parallel path reads bounded byte
  ranges instead and fits large exports better.
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

## Dependencies

- [arrow](https://github.com/Mosaad-M/arrow) `>=1.2.2`: pure-Mojo Arrow IPC
  encoder/decoder (pulls in `flatbuffers` transitively)

No `max` dependency: the parallel path is process-level, driven entirely
by the shell and this repo's own compiled binaries.

## License

MIT
