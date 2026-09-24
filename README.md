# fhir-arrow: Bulk FHIR NDJSON to Apache Arrow (Feather), in pure Mojo

Shreds Bulk FHIR `$export` NDJSON files (Patient, Observation, Condition)
into columnar `.feather` files, using a hand-rolled zero-tree byte scanner
(no JSON tree is ever built) and a pure-Mojo Arrow IPC encoder. No Python,
no C dependencies.

## Quick start

```bash
pixi install                        # resolves arrow (git dep)
pixi run test-ndjson                # 4 tests
pixi run test-fast-shred            # 35 tests
pixi run test-fhir-arrow            # 5 tests
```

End-to-end example:

```mojo
from fhir_arrow import ndjson_to_feather

ndjson_to_feather("patients.ndjson", "patients.feather", "Patient")
```

Read the result with Python:

```python
import pyarrow.feather as f
print(f.read_table("patients.feather"))
```

> See **Known limitations** below: this currently fails against real
> `pyarrow` due to a confirmed bug in the upstream `arrow` package, not in
> this repo. Reading the file back with this repo's own `decode_arrow_file`
> works correctly.

## Architecture

```
NDJSON file (one FHIR resource per line)
        |
        v
  read_ndjson_lines()    ndjson.mojo: splits into raw line Strings.
        |                No JSON parsing happens here at all.
        v
  List[String]
        |
        v
  shred_patient_fast() / shred_observation_fast() / shred_condition_fast()
        |                fast_shred.mojo: scans each line's raw bytes
        |                directly and decodes ONLY the handful of known
        |                fields the v0 schema cares about (name[0].family,
        |                code.coding[0], the value[x] polymorphic choice,
        |                ...). Everything else is skipped in O(bytes)
        |                without ever allocating a representation for it.
        |                No JsonValue tree is built for the resource as a
        |                whole. Only `id` is required; everything else
        |                missing = null, not an error.
        v
  List[PatientRow] / List[ObservationRow] / List[ConditionRow]
        |
        v
  patients_to_feather() / observations_to_feather() / conditions_to_feather()
        |                fhir_arrow.mojo: one column builder per Arrow
        |                type (Utf8/Float64/Bool), assembled into a
        |                RecordBatch, encoded via arrow.mojo's legacy
        |                ArrowType/ArrowArray/encode_arrow_file API.
        |                String columns are pre-sized once from a total
        |                byte-length pass, then filled via indexed writes,
        |                not grown one byte at a time via `.append()`.
        v
  patients.feather / observations.feather / conditions.feather
```

One `.feather` file per resource type, matching how Bulk FHIR `$export`
itself splits output by resource type. There's no sane single flat schema
across three resources this differently shaped.

This targets `arrow.mojo`'s **legacy** `ArrowType`/`ArrowArray`/
`RecordBatch`/`encode_arrow_file` API (the same one `csv_arrow.mojo` uses),
not the newer `dtypes`/`arrays`/`builders.mojo` typed-builder API: as of
`arrow` v1.1.0 there's no bridge from the typed builders to file encoding
yet.

**Why a hand-rolled byte scanner instead of a general JSON parser**: v0 of
this repo used `json.mojo` (a general-purpose recursive-descent parser) to
build a full `JsonValue` tree per record, then read a handful of fields out
of it. That tree-building step turned out to dominate the cost (see
Benchmark below): real Synthea Observations carry dozens of fields
(`meta`, `text`, `category`, `encounter`, `performer`, `referenceRange`,
...) this schema never reads, and every one of them still got parsed and
heap-allocated. `fast_shred.mojo` scans past all of that in raw bytes
without allocating anything for it, and only decodes the ~7-10 fields per
resource type this schema actually extracts. The trade-off, accepted and
intentional: this scanner is less forgiving of malformed or unexpected JSON
shapes than a general tree parser would be. It's a narrow shredder for a
known schema, not a general-purpose FHIR parser.

## Field mapping (v0 scope)

### Patient

| Column | FHIR path | Notes |
|---|---|---|
| `id` | `id` | required |
| `gender` | `gender` | |
| `birth_date` | `birthDate` | kept as the raw ISO string, not parsed to a date type |
| `family_name` | `name[0].family` | first `name` entry only |
| `given_name` | `name[0].given[0]` | first given name of the first `name` entry only |
| `deceased` | `deceasedBoolean` | `deceasedDateTime` is **out of scope**, left null |

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

`value[x]` variants other than `valueQuantity`/`valueString` (e.g.
`valueCodeableConcept`) are **out of scope** for v0: both value columns are
simply left null for that row, not an error. This is the resource that
actually exercises FHIR's choice-type polymorphism and nested coded
arrays, which is the part worth showing off.

### Condition

| Column | FHIR path | Notes |
|---|---|---|
| `id` | `id` | required |
| `patient_ref` | `subject.reference` | |
| `code` / `code_display` | `code.coding[0].{code,display}` | first coding only |
| `clinical_status` | `clinicalStatus.coding[0].code` | |
| `onset_datetime` | `onsetDateTime` | other `onset[x]` variants (e.g. `onsetAge`) are **out of scope**, left null |
| `recorded_date` | `recordedDate` | |

## Benchmark

Measured on a 577-patient Synthea-generated Bulk FHIR export (Massachusetts,
population `500` passed to Synthea, which yields ~577 patients since some
are filtered by age constraints): 266,750 Observation records, 19,025
Condition records, 577 Patient records. Generate the same dataset with
`bench/gen_synthea_data.sh 500 Massachusetts`.

```bash
pixi run mojo run $(cat .mojo_flags) bench_fhir_arrow.mojo <synthea_fhir_dir> <out_dir>
python3 bench/bench_python.py <synthea_fhir_dir> <out_dir>
```

### v0: json.mojo tree parser + byte-by-byte buffers (superseded)

| Resource | Mojo (v0) | Python (json + pandas/pyarrow) |
|---|---|---|
| Patient (577 rows) | 28.7 ms, 20,088 rows/sec | 34.3 ms, 16,841 rows/sec |
| Observation (266,750 rows) | 5,434.0 ms, 49,089 rows/sec | 2,519.0 ms, 105,896 rows/sec |
| Condition (19,025 rows) | 390.3 ms, 48,751 rows/sec | 154.8 ms, 122,905 rows/sec |

The first version of this pipeline used `json.mojo` to parse every record
into a full `JsonValue` tree before reading a handful of fields out of it,
and grew Arrow column buffers one byte/bit at a time via `List.append`
with no capacity pre-reservation. Measured against real Synthea data, that
version was **slower than the Python baseline, roughly 2 to 2.5x on
Observation and Condition**, the opposite of what this project was
pitched on. Root cause was two concrete, fixable things, not a ceiling on
what Mojo can do here:

1. **JSON tree-building dominated the cost.** Real Synthea Observations
   carry dozens of fields this schema never reads (`meta`, `text`,
   `category`, `encounter`, `performer`, `referenceRange`, ...), and every
   one of them still got parsed and heap-allocated into the tree.
   CPython's `json` module is a mature, heavily optimized C extension; a
   heap-allocating tree-walking parser in Mojo had no structural advantage
   over it for this workload.
2. **`build_string_column` grew its value buffer one byte at a time** via
   `List.append` in a loop, with no capacity pre-reservation, versus
   pandas/pyarrow's vectorized C++ internals.

### v1: zero-tree byte scanner + pre-sized buffers (superseded)

Fixed both: `fast_shred.mojo` replaced the `json.mojo`-tree path with a
hand-rolled scanner that never builds a tree at all (see Architecture
above), and `build_string_column` now pre-sizes its buffer from a
total-byte-length pass and writes via indexed assignment instead of
`.append()`. Same dataset, same machine, re-run back to back:

| Resource | Mojo (v1) | Python | v1 vs v0 | v1 vs Python |
|---|---|---|---|---|
| Patient (577 rows) | 10.4 ms, 55,353 rows/sec | 24.5 ms, 23,589 rows/sec | 2.76x faster | **Mojo 2.35x faster** |
| Observation (266,750 rows) | 2,702.6 ms, 98,700 rows/sec | 2,504.0 ms, 106,529 rows/sec | 2.01x faster | Python 1.08x faster |
| Condition (19,025 rows) | 184.1 ms, 103,347 rows/sec | 154.6 ms, 123,040 rows/sec | 2.12x faster | Python 1.19x faster |

Patient beat Python outright at this point. Observation and Condition
improved ~2x over v0 but still trailed Python by 8-19%. Root cause: `_find_key`
re-scanned an object's keys from the start for each field it was asked to
find, one independent linear scan per field, rather than collecting every
wanted field in a single traversal.

### v2: single-pass `_find_keys` (current)

Added `_find_keys`, which walks an object's direct keys once and resolves
an arbitrary set of wanted sibling keys in that one pass (early-exiting once
every slot is filled), instead of one `_find_key` call — and one full
re-scan — per field. Replaced every site that issued 2+ `_find_key` calls
against the same object (Patient's 5 top-level fields + `name[0]`'s 2;
Observation's 7 top-level fields + `coding[0]`'s 3 + `valueQuantity`'s 2;
Condition's 6 top-level fields + `coding[0]`'s 2) with a single `_find_keys`
call each. Genuinely single-key-per-level lookups (`subject.reference`,
`code.coding`, `clinicalStatus.coding`) were left on `_find_key` — they were
never the waste. Same dataset, same machine, re-run back to back (each
number is the average of 2 stable back-to-back runs, after discarding one
cold-cache Python run that included first-import overhead):

| Resource | Mojo (v2) | Python | v2 vs v1 | v2 vs Python |
|---|---|---|---|---|
| Patient (577 rows) | 5.9 ms, 97,591 rows/sec | 22.4 ms, 25,709 rows/sec | 1.76x faster | **Mojo 3.79x faster** |
| Observation (266,750 rows) | 2,248.8 ms, 118,621 rows/sec | 2,489.0 ms, 107,174 rows/sec | 1.20x faster | **Mojo 1.11x faster** |
| Condition (19,025 rows) | 146.3 ms, 130,072 rows/sec | 153.5 ms, 123,987 rows/sec | 1.26x faster | **Mojo 1.05x faster** |

**All three resource types now beat Python.** The margin on Observation and
Condition is real but not large (5-11%) — reported as measured, not rounded
up. It's close enough that a differently-shaped dataset or a slower/faster
`pandas`/`pyarrow` version could plausibly flip it back on those two; the
comfortable win is Patient's, where per-record fixed overhead (six-plus
independent re-scans down to one) dominated more heavily relative to total
work per record.

## Known limitations

- **Real `pyarrow`/DuckDB/Polars cannot currently open the `.feather` files
  this produces. This is a confirmed bug in the upstream `arrow` package,
  not in this repo.** `arrow.mojo`'s `encode_arrow_file` writes an 8-byte
  trailing magic (`"ARROW1\0\0"`) at the end of the file; the real Arrow IPC
  File Format spec requires exactly 6 bytes (`"ARROW1"`, unpadded) as the
  very last bytes of the file, immediately after the 4-byte footer-length
  field. `decode_arrow_file` checks the same (wrong) 8-byte trailer, so
  round-tripping through this library's own reader works and every test in
  this repo passes, but a spec-correct reader rejects the file with
  `ArrowInvalid: Not an Arrow file`. Confirmed this isn't specific to this
  repo's code: `arrow`'s own `csv_arrow.mojo` quick-start example produces
  the identical broken trailer. Fix belongs upstream, in `arrow.mojo`'s
  `_arrow_magic()`/`encode_arrow_file`/`decode_arrow_file` (around
  arrow.mojo:1031, 1107-1233): the trailer write/check needs to use 6 bytes,
  not the shared 8-byte header magic.
- Only the fields listed above are shredded; everything else in a resource
  is dropped, not preserved in an "extra fields" column.
- `id` is the only field treated as required; every other field's absence
  is a null in that row, not an error.
- No streaming: `read_ndjson_lines` loads the whole file into memory as
  `List[String]` before shredding. Lighter than v0's `List[JsonValue]` (no
  tree per line), but still not streaming; would need reworking for exports
  too large to fit in memory.
- `fast_shred.mojo`'s byte scanner is intentionally narrow, not a general
  JSON parser: it's built to shred exactly the field paths listed above
  correctly (including realistic adversarial cases like escaped characters
  and out-of-order keys, see `test_fast_shred.mojo`), not to handle
  arbitrary or malformed JSON gracefully the way `json.mojo`'s tree parser
  would. This trade-off is intentional (see Architecture above), not an
  oversight.

## Dependencies

- [arrow](https://github.com/Mosaad-M/arrow) `>=1.1.0`: pure-Mojo Arrow IPC
  encoder/decoder (pulls in `flatbuffers` transitively)

## License

MIT
