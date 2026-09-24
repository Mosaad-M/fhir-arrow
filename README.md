# fhir-arrow: Bulk FHIR NDJSON to Apache Arrow (Feather), in pure Mojo

Shreds Bulk FHIR `$export` NDJSON files (Patient, Observation, Condition)
into columnar `.feather` files, using a hand-rolled zero-tree byte scanner
(no JSON tree is ever built) and a pure-Mojo Arrow IPC encoder. No Python,
no C dependencies.

## Quick start

```bash
pixi install                        # resolves arrow (git dep) + max
pixi run test-ndjson                # 13 tests
pixi run test-fast-shred            # 45 tests
pixi run test-fhir-arrow            # 8 tests
```

For the large-file (multi-core) path:

```bash
pixi run build-parallel-worker      # compiles parallel_worker
pixi run build-merge-worker         # compiles merge_worker
pixi run build-chunk-planner        # compiles chunk_planner
bench/run_parallel_mojo.sh <ndjson_path> <out_path> <Patient|Observation|Condition> [num_workers]
```

See **Benchmark → Phase D** below for when this is actually worth reaching
for (large files only — the fixed per-process cost doesn't pay for itself
on small ones, in either Mojo or Python).

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

### Phase A: zero-copy line reading (current)

`read_ndjson_lines` used to split the whole file into one owned `String`
per line (`content.split("\n")` plus an explicit copy of each survivor) —
for the 266,750-row Observation file, ~266K String allocations before
`fast_shred` ever ran. It now reads the file once and returns `(content,
spans)`, where `spans` is a list of `(start, end)` byte offsets into that
one buffer; `shred_patient_fast`/`shred_observation_fast`/
`shred_condition_fast` take a byte `Span` slice of it directly instead of
an owned line `String`, so no per-line allocation happens at all.

The first attempt at this was, surprisingly, *slower* than v2 — a
hand-rolled `while i < n: if b[i] == LF: ...` scan over the byte buffer
turned out to be roughly 25x slower than Mojo's stdlib `String.find()`
used in a loop (measured directly: ~450ms vs ~17ms for the same
266,750-line scan), evidently because the stdlib search is vectorized and
a naive per-byte `Span` index loop isn't. Fixed by using `.find()` instead
of a manual scan; the "zero per-line allocation" property is unaffected,
since `.find()` only searches, it doesn't allocate. Full writeup in
`tasks/lessons.md`.

Same dataset, same machine, re-run back to back:

| Resource | Mojo (Phase A) | Python | A vs v2 | A vs Python |
|---|---|---|---|---|
| Patient (577 rows) | 5.7 ms, 100,909 rows/sec | 23.6 ms, 24,402 rows/sec | ~1.03x faster | **Mojo 4.13x faster** |
| Observation (266,750 rows) | 2,155.8 ms, 123,735 rows/sec | 2,511.6 ms, 106,208 rows/sec | ~1.04x faster | **Mojo 1.17x faster** |
| Condition (19,025 rows) | 147.0 ms, 129,464 rows/sec | 152.7 ms, 124,573 rows/sec | ~flat vs v2 (noise-level on 19K rows) | **Mojo 1.04x faster** |

A modest, real improvement over v2 on Patient/Observation; Condition is
within run-to-run noise at this row count.

### Phase B: escape-free fast path in `_extract_string`

Most FHIR field values (ids, LOINC codes, ISO dates) never contain an
escape. `_extract_string` now scans for the closing quote checking only
for a backslash; when none is found, the string's exact length is already
known, so the result buffer is pre-sized once and bulk-copied instead of
growing via `.append()` per byte through the original escape-handling
branches. Falls back to the original byte-by-byte decoder the moment a
backslash is actually seen — output is unchanged either way (5 new direct
tests plus all 45 prior `test_fast_shred.mojo`/`test_ndjson.mojo`/
`test_fhir_arrow.mojo` cases confirm this).

An isolated 2M-call micro-benchmark on a realistic ~57-byte display string
shows a real ~30% per-call improvement (406ms vs 584ms for 2M calls, old
vs new). The full `bench_fhir_arrow` run, however, shows **no measurable
change** from Phase A's numbers — other per-record costs (`_find_keys`
scanning, column building, Feather encoding, file I/O) apparently dominate
total wall-clock time enough to swamp this one function's share entirely.
Reporting both numbers rather than only the flattering one: the
optimization is real, it's just not the bottleneck at this pipeline's
current profile.

### Phase C: finish the buffer-growth cleanup

The v1 fix only pre-sized `build_string_column`'s *value* bytes — its own
`null_bits` list, plus `build_float64_column`'s and `build_bool_column`'s
`null_bits`/`value_bits`, and the per-field intermediate lists in the
three `*_to_record_batch` functions (`ids`, `genders`, `codes`, ...), were
all still growing via `.append()` with no capacity reserved even though
the final length is known before the loop starts. Capacity-reserved all
of them (`List[T](capacity=N)`, the same technique already used
elsewhere in this codebase) — performance-only, no behavior change (all 5
`test_fhir_arrow.mojo` cases pass unchanged).

### Checkpoint: A + B + C combined

Same dataset, same machine, re-run back to back:

| Resource | Mojo (A+B+C) | Python | vs v2 | vs Python |
|---|---|---|---|---|
| Patient (577 rows) | 5.5 ms, 105,119 rows/sec | 24.6 ms, 23,437 rows/sec | 1.07x faster | **Mojo 4.48x faster** |
| Observation (266,750 rows) | 2,131.9 ms, 125,125 rows/sec | 2,621.3 ms, 101,762 rows/sec | 1.05x faster | **Mojo 1.23x faster** |
| Condition (19,025 rows) | 140.8 ms, 135,118 rows/sec | 154.2 ms, 123,386 rows/sec | 1.04x faster | **Mojo 1.10x faster** |

Modest, real, across-the-board gains over v2 (roughly 4-7%) rather than a
dramatic jump — most of the individual phase A/B/C changes were each
small or fully swamped by other costs in isolation (see phase B above),
but they compound. The margins on Observation (+23%) and Condition (+10%)
are meaningfully more comfortable than v2's thin +11%/+5%, though still
not as decisive as Patient's.

Per the project plan, this is a deliberate checkpoint: phases D
(parallelism) and E (SIMD scanning) are bigger, riskier changes, and
phase E in particular is only worth attempting if a real gap remains
after D.

### Phase D: parallelism (process-level, not in-process threads)

The plan called for reusing `1brc_arrow`'s in-process worker pattern
(`max.algorithm.parallelize` with a capturing `@parameter def` closure per
worker). That pattern does not work on this repo's toolchain: **confirmed
empirically** that Mojo 1.1.0/max 26.6.0 removed `fn` entirely (only `def`
exists now), every nested `def` closure is unconditionally tagged
`capturing` regardless of what it actually captures, and `parallelize`'s
`FuncType` bound only accepts genuinely non-capturing (module-level)
functions — which in turn can't receive runtime shared state via closures,
mutable module-level globals (unsupported: "global variables are not
supported"), or dynamic values bound as compile-time parameters ("cannot
use a dynamic value in a parameter list"). `1brc_arrow` itself is pinned to
the older Mojo 1.0.0/max 26.5.0 toolchain, where the capturing-closure
pattern still worked. The full trail of minimal reproductions is in
`tasks/lessons.md`.

So this phase uses OS-process parallelism instead, and went through two
slower designs before landing on the one that actually helps (all measured,
not guessed — see `parallel_worker.mojo`'s header for the same writeup in
code):

1. **Row-index range into the whole file.** Each worker called
   `read_ndjson_lines` on the *entire* file to compute the span list it
   would then slice a subset of — so 8 workers redundantly paid the
   full-file read+scan cost. 8-worker Observation: **4,748 ms**, slower
   than the 2,131.9 ms sequential baseline.
2. **Physically splitting the file with `split` first.** Correct, but
   `Observation.ndjson` is 262 MB, and `split` has to copy every byte of
   it to disk before any shredding starts, then `merge_worker` re-reads
   all the chunk outputs afterward. That I/O alone (~1s to split) was
   comparable to the entire sequential baseline. 8-worker Observation:
   **2,819 ms** — still slower, though much closer.
3. **Byte-range reads via seek, computed once (current).** A new
   `chunk_planner` binary reads the file exactly once to find
   newline-aligned byte boundaries for N chunks. Each `parallel_worker`
   then opens the *original* file directly and reads only its own
   `[start_byte, end_byte)` range via `open(path).seek(...).read(...)` — no
   whole-file re-read, no physical copy. `merge_feathers` combines the N
   chunk Feather files into one by concatenating their RecordBatches
   (Arrow's IPC file format natively supports multiple batches per file,
   so this is a batch concat, not a byte-level merge or a re-shred).

Per the user's explicit fairness decision: since Mojo got multi-core
shredding, the Python baseline got multiprocessing too
(`bench_python_parallel.py`, a `ProcessPoolExecutor` splitting the same
file the same way), so this stays a parallel-vs-parallel comparison, not
parallel-Mojo-vs-single-threaded-Python. 8 workers both sides (physical
core count on the benchmark machine), same Synthea data:

| Resource | Sequential Mojo (A+B+C) | Parallel Mojo | Parallel Python | Parallel Mojo vs Parallel Python |
|---|---|---|---|---|
| Patient (577 rows) | 5.5 ms | 99.4 ms | 654.0 ms | **Mojo 6.58x faster** |
| Observation (266,750 rows) | 2,131.9 ms | 1,685.0 ms | 1,720.2 ms | **Mojo 1.02x faster** |
| Condition (19,025 rows) | 140.8 ms | 202.3 ms | 723.3 ms | **Mojo 3.58x faster** |

**Honest reading, not a clean "multi-core wins" headline**: Mojo's
parallel path beats Python's parallel path on all three resource types,
but going parallel only beat *sequential Mojo* for Observation (1,685.0 ms
vs. 2,131.9 ms) — for Patient and Condition, both languages' parallel runs
are slower than their own sequential runs (Patient: 99.4 ms parallel vs.
5.5 ms sequential; Condition: 202.3 ms parallel vs. 140.8 ms sequential).
Process-spawn overhead (8 process launches, each with real fixed cost) is
large enough that it only pays for itself once a chunk's actual shredding
work is big enough to amortize it — true here only for the 266,750-row
file. The reason Mojo still wins the parallel-vs-parallel comparison even
where parallelism doesn't pay off over sequential is that Mojo's fixed
cost per process is much lower than Python's: no interpreter startup, no
`pandas`/`pyarrow` import per worker, no pickling results back across the
process boundary. Practical takeaway: process-level parallelism is worth
reaching for here only above some file-size threshold, in either language
— for smaller files, plain sequential is simply better, and this repo's
`ndjson_to_feather` (sequential) remains the right default; `parallel_worker`
+ `chunk_planner` + `merge_worker` (via `bench/run_parallel_mojo.sh`) is
there for large files specifically.

An explicit equivalence test (`test_parallel_chunked_equivalent_to_sequential`
in `test_fhir_arrow.mojo`) proves chunk+merge produces identical row
values, in identical order, to the plain sequential path on the same
input, before any of these numbers were trusted.

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
- No streaming on the sequential path: `read_ndjson_lines` loads the whole
  file into memory as one `String` before shredding (lines are then
  zero-copy byte spans into it, not separate allocations, but the whole
  file is still resident at once). The parallel path (`chunk_planner` +
  `parallel_worker`, see Benchmark → Phase D) reads bounded byte ranges via
  seek instead, and is the better fit for exports too large to hold in
  memory in one piece, though it isn't a true streaming reader either.
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

No `max` dependency: Phase D's parallel path investigated
`max.algorithm.parallelize` (see Benchmark → Phase D) but ended up not
using it — the shipped parallel path is process-level, driven entirely by
the shell (`bench/run_parallel_mojo.sh`) and this repo's own compiled
binaries, so `max` was removed from `pixi.toml` again once that was clear.

## License

MIT
