# fhir-arrow: Bulk FHIR NDJSON to Apache Arrow (Feather), in pure Mojo

Shreds Bulk FHIR `$export` NDJSON files (Patient, Observation, Condition)
into columnar `.feather` files, using a pure-Mojo JSON parser and a pure-Mojo
Arrow IPC encoder. No Python, no C dependencies.

## Quick start

```bash
pixi install                        # resolves arrow + json (git deps)
pixi run test-ndjson                # 4 tests
pixi run test-resources             # 11 tests
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
  read_ndjson()          ndjson.mojo: json.mojo's parse_json() per line
        |
        v
  List[JsonValue]
        |
        v
  shred_patient() / shred_observation() / shred_condition()
        |                resources.mojo: walks known FHIR paths
        |                (name[0].family, code.coding[0], the
        |                 value[x] polymorphic choice, ...) into
        |                a flat row struct. Only `id` is required;
        |                everything else missing = null, not an error.
        v
  List[PatientRow] / List[ObservationRow] / List[ConditionRow]
        |
        v
  patients_to_feather() / observations_to_feather() / conditions_to_feather()
        |                fhir_arrow.mojo: one column builder per Arrow
        |                type (Utf8/Float64/Bool), assembled into a
        |                RecordBatch, encoded via arrow.mojo's legacy
        |                ArrowType/ArrowArray/encode_arrow_file API
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
- No streaming: `read_ndjson` loads the whole file into memory as
  `List[JsonValue]` before shredding. Fine for the benchmark sizes here;
  would need reworking for exports too large to fit in memory.

## Dependencies

- [json](https://github.com/Mosaad-M/json) `>=1.1.0`: pure-Mojo JSON parser
- [arrow](https://github.com/Mosaad-M/arrow) `>=1.1.0`: pure-Mojo Arrow IPC
  encoder/decoder (pulls in `flatbuffers` transitively)

## License

MIT
