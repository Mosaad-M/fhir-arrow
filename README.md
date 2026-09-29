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

Real `pyarrow` interop is verified: the upstream `arrow >=1.1.1`
dependency fixes the Feather-format bugs that previously blocked this
(magic bytes, Footer verification, RecordBatch body length — all fixed
upstream, not in this repo). Confirmed directly against real Synthea
data: `ndjson_to_feather` on all 577 Patient records, then read back with
`pyarrow.feather.read_table()` — correct schema, correct values, all 577
rows.

## Architecture

```
NDJSON file (one FHIR resource per line)
        |
        v
  read_ndjson_lines()    ndjson.mojo: reads the file once into one owned
        |                buffer and returns (content, spans), where spans
        |                are zero-copy (start, end) byte offsets into it.
        |                No JSON parsing, no per-line allocation.
        v
  Span[UInt8] per line (zero-copy slices of one buffer)
        |
        v
  shred_patient_fast_into_columns() / shred_observation_fast_into_columns()
  / shred_condition_fast_into_columns()
        |                fast_shred.mojo's scanning primitives
        |                (_find_keys/_coding0_at/_extract_number/...)
        |                decode ONLY the handful of known fields the v0
        |                schema cares about (name[0].family, code.coding[0],
        |                the value[x] polymorphic choice, ...), writing
        |                decoded bytes DIRECTLY into the column builders
        |                below -- fused into the same scan, not via an
        |                intermediate row struct with heap-allocated
        |                String fields (see Benchmark -> Phase H/Phase 2).
        |                Everything else is skipped in O(bytes) without
        |                ever allocating a representation for it. Only
        |                `id` is required; everything else missing = null.
        v
  PatientColumns / ObservationColumns / ConditionColumns
        |                fhir_arrow.mojo: StringColumnBuilder/
        |                BoolColumnBuilder/Float64ColumnBuilder, one per
        |                Arrow type, appended into directly as each line is
        |                shredded. finish() assembles a RecordBatch, encoded
        |                via arrow.mojo's legacy ArrowType/ArrowArray/
        |                encode_arrow_file API.
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
| `raw_json` | the entire original resource | verbatim, not run through JSON-escape decoding -- see "Extra fields" below |

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
| `raw_json` | the entire original resource | same as Patient's `raw_json` -- see "Extra fields" below |

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
| `raw_json` | the entire original resource | same as Patient's `raw_json` -- see "Extra fields" below |

### Extra fields: `raw_json`

Only the fields listed above are individually shredded into their own
typed columns. Everything else in a resource (`meta`, `text`, `extension`,
`identifier`, `telecom`, `category`, `encounter`, `performer`,
`referenceRange`, and every other FHIR field this v0 schema doesn't model)
is not modeled at all -- but it isn't silently lost either: `raw_json`
carries the complete, unmodified original resource JSON object, giving
downstream consumers a fallback to parse further themselves without this
project needing to model every possible field. It is **not** run through
JSON-escape decoding, since decoding is only meaningful within a single
field's value, not across a whole object whose own structural `"`/`{`/`}`
characters must survive unmodified -- mirrors hl7-arrow's `raw_message`
column exactly, one resource per row here rather than one message per
`\r`-delimited group of segments.

Unlike hl7-arrow's Observations table (which duplicates the raw message
once per OBX row within a message), there is no such duplication here:
Bulk FHIR NDJSON is already one full resource object per line, so
`raw_json` is exactly the source line each shredder already receives, no
new span computation and no per-row-scoped subsetting needed. This is a
real, non-free addition -- see "`raw_json`: extra-fields passthrough" in
Benchmark below for the measured cost and verification.

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

### Phase A: zero-copy line reading

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

### Phase E: SIMD-accelerated structural scanning (current)

`_skip_string` and `_skip_value`'s object/array depth-counting loop used to
advance one byte at a time while nothing structurally interesting was
happening. Both now use a SIMD-accelerated search (`_simd_find2`/
`_simd_find3` in `fast_shred.mojo`) to jump straight to the next candidate
byte (`"`/`\` for strings; `"`/open-bracket/close-bracket for the
object/array depth loop) instead of checking one byte at a time — the
scalar logic that decides what a candidate byte *means* (escape handling,
depth increment/decrement) is completely unchanged. This is a deliberately
narrower design than full simdjson-style bulk structural classification
(which computes escape/quote parity across a whole buffer and can break at
chunk boundaries): here, chunking only changes *how fast* a candidate is
located, never what happens once it's found, so there's no
boundary-crossing correctness class of bug to worry about the way real
simdjson has to guard against.

The technique mirrors `1brc_arrow.mojo`'s `find_byte_simd_reduce` (XOR two
SIMD vectors, `reduce_min() == 0` iff any lane matched), extended from one
target byte to two/three via elementwise `min()` of the XOR vectors — a
lane is exactly 0 iff it matched *any* target. `SIMD_WIDTH = 32` (AVX2)
reuses `1brc_arrow`'s already-CI-validated choice for this repo's declared
`linux-64`/`osx-arm64` platforms. One thing confirmed empirically rather
than assumed: SIMD `==` between two full vectors collapses to a single
reduced `Bool` on this toolchain rather than an elementwise mask — which is
exactly why `1brc_arrow` uses XOR+`reduce_min` instead of `==`, and why
this code does too.

9 new tests cover the boundary cases this kind of chunked search can
actually get wrong (unlike the escape/depth logic itself, which is
untouched): a candidate at exactly `SIMD_WIDTH - 1`/`SIMD_WIDTH`/
`SIMD_WIDTH + 1` bytes from the scan start, a span shorter than
`SIMD_WIDTH` (pure scalar-tail path), a span not a multiple of
`SIMD_WIDTH`, multiple candidates in one chunk (must return the first),
and a backslash as the literal last byte before the boundary. One bug
surfaced immediately, in the test itself, not the implementation: the
first version of the backslash-at-boundary test asserted the wrong index
(off-by-one — 32 `a`s followed by one backslash puts the backslash at
index 32, not 33); caught by running it, fixed in the test, not silenced.
All 66 pre-existing tests (13 ndjson + 45 fast_shred + 8 fhir_arrow) still
pass unchanged, proving behavioral equivalence with the byte-by-byte
version it replaced.

Same dataset, same machine, sequential path (the recommended default):

| Resource | Mojo (A+B+C) | Mojo (Phase E) | Python | E vs A+B+C | E vs Python |
|---|---|---|---|---|---|
| Patient (577 rows) | 5.5 ms | 5.13 ms | 22.8 ms | 6.7% faster | **Mojo 4.44x faster** |
| Observation (266,750 rows) | 2,131.9 ms | 2,063 ms | 2,472 ms | 3.2% faster | **Mojo 1.20x faster** |
| Condition (19,025 rows) | 140.8 ms | 130 ms | 153.3 ms | 7.7% faster | **Mojo 1.18x faster** |

Real but modest gains, smaller than A+B+C's combined effect. The reason is
structural: `_extract_string`'s Phase B fast path already handles the
common case (a short field value) in effectively one pass regardless of
SIMD, and most FHIR field values here (ids, codes, dates) are well under
32 bytes — short enough that the chunked loop never executes at all, only
the scalar tail does, identical cost to before. SIMD's actual win is
concentrated in *skipping large substructures entirely* (an `extension`
array, a big `category`/`meta` object) via `_skip_value`, which happens
less often per record than short-field extraction does. Reporting the real
number rather than the hoped-for one, same standard as every phase above.

The parallel path shares these same primitives, so it improved too (same
Synthea data, 8 workers both sides):

| Resource | Parallel Mojo (Phase D) | Parallel Mojo (Phase E) | Parallel Python | E vs Python |
|---|---|---|---|---|
| Patient (577 rows) | 99.4 ms | 60 ms | 640.6 ms | **Mojo 10.68x faster** |
| Observation (266,750 rows) | 1,685.0 ms | 1,610 ms | 1,735.0 ms | **Mojo 1.08x faster** |
| Condition (19,025 rows) | 202.3 ms | 160 ms | 687.4 ms | **Mojo 4.30x faster** |

The sequential-vs-Python comparison above remains the headline metric per
the project's own phase-D finding that sequential is the safer default;
the parallel numbers are reported for completeness since the same
primitives are shared, not as a replacement headline.

### Phase F: batch multi-hit SIMD scanning — tried, measured, reverted

Bumping the `arrow` dependency to `1.1.2` (a `List.extend()` fix in
`arrow` itself, unrelated to this repo — see its own changelog) moved the
baseline to Patient 4.888 ms / Observation 1863.4 ms / Condition 119.9 ms
on the same data, purely from faster Feather encoding. Real record
analysis of that baseline (765-byte Observation records: ~39% of bytes
are fields this v0 schema skips entirely — `resourceType`/`meta`/
`category`/`encounter`) motivated a real attempt to close the shredding
gap further: instead of Phase E's "find the *first* candidate per chunk,
early-exit," batch-extract *every* hit position from one loaded chunk
(using `SIMD.eq()` as an explicit method — confirmed to return a real
elementwise `SIMD[DType.bool, W]`, unlike the `==` *operator*, which
collapses to a scalar `Bool` — combined with `|` across targets), so the
SIMD setup cost is amortized across every hit in a dense window instead
of paid once per hit.

**Measured directly, not assumed, and it was a real regression, not just
underwhelming**: the first version (returning a fresh heap-allocated
`List[Int]` per chunk load) measured 3-13x *slower*. Switching to a
stack-allocated fixed buffer (`SIMD[DType.int64, 32]`, reused per call,
no heap allocation) recovered most of that but was still 1.5-9x slower
than the Phase E baseline. Root cause, found by tracing through both
designs rather than guessing: extracting *every* hit from a chunk
requires an unconditional full 32-lane scan (`for j in range(32): if
mask[j]: ...`), while Phase E's early-exit design (`return pos + j` the
moment a match is found) does far less work for the common case — and
for real FHIR JSON, that common case (a string's own closing quote, a
single structural delimiter) *is* almost always exactly one hit per
call. Batching only pays off when a chunk holds several hits worth
amortizing the scan over, and for this workload's actual density profile
that's the exception, not the rule — confirming and sharpening Phase E's
own finding, not contradicting it.

Reverted `_skip_string` fully back to the early-exit design
(`_simd_find_first2`); `_skip_value`'s bracket-depth loop the same
(`_simd_find_first3`) after it showed the identical pattern. Net result:
functionally the same algorithm Phase E already had, re-verified against
the same benchmark — Patient 4.833 ms, Observation 1670.8 ms (10.3%
faster than the post-bump baseline), Condition 111.8 ms (6.7% faster) —
essentially a wash on top of the `arrow` version bump, not a new win from
this attempt itself, and reported as such rather than credited to
something that didn't pan out. All 61 `fast_shred.mojo` tests pass
(several new ones added for the escaped-quote-adjacency edge cases this
investigation surfaced), full suite and real `pyarrow` interop
re-verified unchanged.

### Phase G: eliminate the row-to-column transpose copy, guided by a real profiler

Instead of guessing at the next bottleneck, this phase started with a real
macOS `sample`-based profiling pass (debug-symbol binary, 23.7s of actual
execution, ~110K stack samples, idle background threads correctly
excluded from the analysis). Real breakdown of actual work time: **JSON
scanning 36.2%, allocator (tcmalloc) overhead 24.0%, Arrow encoding
13.3%, column building 8.3%**, the rest smaller. The allocator bucket had
never been targeted and was bigger than Arrow encoding and column
building combined.

Reading the code (not guessing) found a precise, narrow cause: every
extracted field string was allocated *twice* — once during shredding
(`_extract_string`, unavoidable), and a second time during the
row-to-column transpose in `fhir_arrow.mojo` (`ids.append(rows[i].id)` —
an implicit copy out of a borrowed row reference). Fixed by making
`patients_to_record_batch`/`observations_to_record_batch`/
`conditions_to_record_batch` consume `rows` (`var rows: List[XRow]`
instead of borrowed) and adding an `into_parts(deinit self) -> Tuple[...]`
method to each row struct that moves every field out in one shot — a
struct method is required here; `deinit` as a parameter convention only
works on struct methods, confirmed by the compiler rejecting a
free-function attempt. `.pop()` (used for consuming iteration) consumes
from the back, so each output column list is built in reverse row order
and `.reverse()`d once before use — a new dedicated test per resource
type (`test_*_to_record_batch_preserves_row_order`) exists specifically
to catch a missing/wrong `.reverse()` call, and was confirmed to actually
catch it: temporarily deleting one `.reverse()` call made the test fail
with the exact wrong row order, restoring it made it pass again.

**Real numbers**, same data: Patient 4.833→4.887 ms (flat — expected,
allocator savings on 577 rows are small in absolute terms), Observation
1670.8→1659.6 ms (0.7% faster), Condition 111.8→106.3 ms (5.0% faster).

**Honest finding, from a second profiling pass after the fix, not just
"tests still pass"**: the allocator-overhead bucket **did not shrink**
(24.0% → 24.5%, unchanged within noise), even though the fix is correct,
tested, and gives a real small win. The likely explanation: Mojo's
`String` probably has small-string optimization, and most FHIR field
values (ids, codes, short dates) are short enough to never have touched
the heap on the transpose copy in the first place — so removing that
copy saved real, measurable CPU work (struct/pointer bookkeeping), just
not the malloc/free churn the original hypothesis assumed. The true
source of the 24% allocator bucket is most likely the *original*
`_extract_string` calls during shredding (deliberately left untouched by
this phase's narrow scope), or the parallel path's own resources, not
the transpose step. **Lesson carried forward from Phase F, reinforced
here**: a real profiler tells you *where* time goes; it doesn't tell you
*why* a specific line is expensive, and a plausible mechanism (like "this
copy must be a malloc") still needs to be checked against a second
profiling pass, not assumed correct just because the fix compiled and
the wall-clock number moved in the right direction.

**Correction (see "Root-causing the 'allocator overhead' bucket" below,
a later session)**: the `_extract_string` guess above was already stale
by the time it was checked -- Phase 2 (later in this same document)
retired the entire code path that called it. Re-profiling the current
pipeline found a real, different, much larger issue instead: a stale
`arrow` dependency version.

Verified for real, not just via the fixture-scale unit tests: generated a
real `patients.feather` from all 577 Synthea Patient records and compared
every `id` value, in order, directly against the source NDJSON file — an
exact match, not just "577 rows came back."

### Phase H: fuse extraction with column-building — staged, gated on real profiling

Phase G's honest finding pointed at `_extract_string`'s per-field
allocation during shredding as the real remaining source of allocator
overhead. The full fix is architectural — write decoded bytes directly
into the Arrow column builder during the scan, instead of shredding into
a row struct with heap-allocated `String` fields that get built once and
then thrown away after `build_string_column` copies their bytes again.
Given the previous two attempts at "this should obviously help" both
underperformed the hypothesis (Phase F was a real regression, Phase G's
predicted allocator win didn't materialize), this was staged and gated
on real measurement rather than committed to all at once.

**Phase 0** (quick, independent): `_extract_string`'s existing fast path
still copied its result byte-by-byte in a loop despite its own docstring
claiming a bulk copy — pre-sizing capacity avoided reallocation but not
the per-element copy cost. Fixed with `result.extend(b[start+1:j])`
(confirmed `List[UInt8].extend()` accepts a `Span[UInt8]` slice directly).
All 61 existing tests pass unchanged. Benchmarked honestly: three runs on
real data showed this within normal run-to-run noise at the pipeline
level (Observation ranged 1554.7–1626.0ms across runs) — mechanically
correct and worth keeping, but no measurable pipeline-level win on its
own, consistent with the same small-string-optimization explanation from
Phase G.

**Phase 1** (the real test, Patient only): built `StringColumnBuilder`/
`BoolColumnBuilder`/`PatientColumns` — streaming Arrow column builders
that `shred_patient_fast_into_columns` appends directly into during the
scan, reusing the exact same `_find_keys`/`_first_array_element`/
`_extract_bool` field-finding logic as `shred_patient_fast` (only the
destination of decoded values changes). The escape-decoding core was
factored out of `_extract_string_escaped` into
`_decode_escaped_string_into`, which writes into a caller-supplied buffer
instead of always building a fresh `String` — reused by both the old
row-based path (unchanged behavior, now a thin wrapper) and the new
builder's escaped-value case. `shred_patient_fast`/`PatientRow` were left
completely untouched as the correctness oracle for this phase — kept
side-by-side, not wired into production `ndjson_to_feather` yet.

New tests: parity checks against the row-based oracle for the minimal,
name-present, deceased-boolean, missing-id, and escaped-character cases,
plus a dedicated multi-row column-alignment test — the one new
correctness risk this design introduces, since a missing `append`/
`append_null` call for any single column would silently shift every
subsequent row in that column relative to the others. Confirmed this
test actually catches it: temporarily deleting one `append_null()` call
made the suite fail immediately with the exact expected mismatch,
restoring it made everything pass again. Also confirmed via real
`pyarrow`: `t_old.equals(t_new)` on all 577 real Synthea Patient rows —
`True`, byte-for-byte table equality between the old and fused paths, not
just "same row count."

**Real numbers, this time actually validating the hypothesis**:
- Wall-clock (30-iteration average, real Patient data): 3.94ms → 3.37ms
  (**~14% faster**).
- The gate — a second `sample`-based profiling pass, old vs. fused,
  30x3000 iterations each for enough samples: allocator overhead
  **9.9% → 4.7% of real work time — roughly halved**, not just
  unchanged-within-noise the way Phase G's identical mechanism-check
  came back. This is the first of the three "reduce allocation" attempts
  this session where the profiler actually confirms the predicted
  mechanism, not just a wall-clock number moving the right direction.

### Phase 2: extend the fused path to Observation and Condition, retire the row-based path

Phase 1's gate passed decisively, so Phase 2 applied the same pattern to
Observation (10 columns, including the polymorphic `valueQuantity`/
`valueString` handling via a new `Float64ColumnBuilder`) and Condition (7
columns), wired all three fused paths into actual production use
(`ndjson_to_feather`/`ndjson_range_to_feather`), and retired the row-based
path entirely: `PatientRow`/`ObservationRow`/`ConditionRow` (and
`resources.mojo`, which held them, deleted outright),
`shred_patient_fast`/`shred_observation_fast`/`shred_condition_fast`,
`build_string_column`/`build_required_string_column`/
`build_float64_column`/`build_bool_column`, and the `*_to_record_batch`/
`*_to_feather` transpose functions — consistent with this project's
established pattern of not carrying two parallel implementations forward
once the new one is proven. `fast_shred.mojo` shrank from 669 to 484
lines; `resources.mojo` disappeared entirely.

Field-finding logic itself did not change — `shred_observation_fast_into_columns`/
`shred_condition_fast_into_columns` reuse the exact same `_find_keys`/
`_find_key`/`_coding0_at`/`_extract_number` primitives the retired
row-based shredders used, only the destination of decoded values changed.
`test_fhir_arrow.mojo` carries 31 tests: parity coverage ported from every
case the retired `test_fast_shred.mojo` tests had for Observation and
Condition (including the adversarial ones — escaped structural characters
inside a skipped field, `code` key collisions, out-of-order keys with
unrelated fields interspersed, multiple `coding[]` entries, a unicode
escape inside a skipped field), plus dedicated column-alignment tests for
both Observation and Condition specifically (more sibling-column surface
than Patient's 6, especially around the polymorphic value[x] branch).
Confirmed the alignment test actually catches the bug class it targets,
the same way Phase 1's did: temporarily dropped the `value_string`
null-append in the polymorphic branch, watched the suite fail with the
exact expected mismatch, restored it.

**Real numbers, same Synthea data, same machine** (two stable back-to-back
runs after discarding one higher first run, same convention used
throughout this benchmark history):

| Resource | Pre-fusion (Phase G) | Fused (Phase 2) | Improvement | Python | Mojo vs Python |
|---|---|---|---|---|---|
| Patient (577 rows) | 4.887 ms | ~4.2 ms | ~14% faster | 35.2 ms | **Mojo ~8.4x faster** |
| Observation (266,750 rows) | 1,659.6 ms | ~1,136 ms | **~31.6% faster** | 2,503.9 ms | **Mojo ~2.2x faster** |
| Condition (19,025 rows) | 106.3 ms | ~67.8 ms | **~35.9% faster** | 152.6 ms | **Mojo ~2.25x faster** |

Observation and Condition's gains are substantially larger than Patient's
~14% — both resource types have more columns, more fields extracted per
row, and (Observation especially) a much larger row count, so the
per-field allocation this phase eliminates adds up more. This also
resolves v2's thin, noise-adjacent 5-11% margin over Python on Observation
and Condition (see above): the margin is now decisively 2.2x+, not a
close call.

A follow-up `sample`-based profiling pass (debug-symbol binary, 20s window,
~1,026 samples, one full Patient+Observation+Condition run dominated
time-wise by Observation) confirms the allocator-overhead reduction is not
Patient-specific: allocator overhead dropped from Phase G's baseline
**~24.0% to ~15.6%** of real work time on this Observation-heavy run — a
smaller relative drop than Patient's 9.9%→4.7% (expected: Observation
extracts more distinct fields per row, so the fused elimination applies to
a larger, but proportionally similar, share of per-row work), with JSON
scanning (~35.7%) and Arrow encoding (~14.0%) essentially flat versus
Phase G, exactly as expected since neither of those was touched by this
phase.

Verified for real, not just at fixture scale: `pyarrow.feather.read_table()`
against fresh output for all three resource types, every field compared
directly against the source NDJSON (not just row counts) — 577 Patient
rows, 266,750 Observation rows, 19,025 Condition rows, zero mismatches on
any of the 5-7 shredded fields per resource type.

### SIMD_WIDTH: 32 → 16, measured with a cross-language benchmark first

`_skip_string`/`_skip_value`'s SIMD candidate search (`_SIMD_WIDTH`, used
by both since Phase E) was 32 bytes, chosen to match `1brc_arrow`'s AVX2
width. Building a standalone cross-language comparison (same early-exit
search algorithm, realistic 5-40 byte field gaps, implemented natively in
Mojo, C, Rust, and Zig, all verified against identical checksums) surfaced
that this specific access pattern is faster at width=16 than width=32 —
confirmed directly on this repo's own code, not just the standalone
benchmark: ~40% faster in isolation, consistent across repeated runs.
Width=16 is also the *more* portable choice, not less: it's baseline SSE2
on every x86_64 CPU (not AVX2-specific like 32 was), and the native NEON
register width on arm64.

At the full pipeline level the real-world win is real but modest — Patient
~flat, Observation ~3-4% faster, Condition trending faster but noisy
across runs — much smaller than the isolated 40%, because this primitive
is only one contributor within JSON scanning's ~44.5% share of total real
work, not the whole of it. Reported honestly rather than extrapolated from
the isolated number. Full test suite green, real pyarrow interop
re-verified against fresh Patient output.

### `raw_json`: extra-fields passthrough

Closes the "everything else in a resource is dropped" gap named in Known
limitations, mirroring hl7-arrow's already-proven `raw_message` design: a
new `StringColumnBuilder.append_raw(b)` (bulk `.extend()`, no
JSON-escape decoding) appends each resource's full source line verbatim
as the last column on all three tables. Confirmed simpler here than in
hl7-arrow: Bulk FHIR NDJSON is already exactly one resource object per
line (`find_line_spans` in `ndjson.mojo`), so `raw_json` is just the same
`b` span each `shred_*_fast_into_columns` function already receives — no
new span computation, and (unlike hl7-arrow's Observations table) no
per-row duplication concern either, since it's already one resource per
row.

Confirmed the column-alignment risk applies here too, same as every other
column this project has added: temporarily dropped the Patient
`raw_json.append_raw(b)` call and confirmed the suite crashes (an
out-of-bounds read against the now-misaligned offsets), then restored it.
9 new tests (33 total in `test_fhir_arrow.mojo`): per-resource-type
byte-verbatim checks (an escaped quote inside a shredded field survives
un-decoded in `raw_json`, and a key this schema doesn't otherwise shred,
e.g. `resourceType`/`meta`/`encounter`, is preserved), plus `raw_json`
assertions folded into each resource type's existing column-alignment
test.

**Real, accepted cost, measured directly via `git stash` on the same
regenerated Synthea dataset (562 Patient / 296,901 Observation / 19,571
Condition rows), before/after, same machine:**

| Resource | Before `raw_json` | After `raw_json` |
|---|---|---|
| Patient | ~3.2 ms | ~8.5 ms |
| Observation | ~948 ms | ~1,853 ms |
| Condition | ~49 ms | ~105 ms |

Roughly **doubles** wall-clock time across all three resource types --
larger than "a small per-row cost." Root cause: for most of these
resources, the full JSON object (every field this project doesn't
otherwise shred included) is comparable to or larger than the handful of
scalar bytes previously extracted, so copying it in full roughly doubles
the bytes actually written per row. That's the real, measured price of
"one column, full text, no per-field modeling," reported plainly rather
than as a rounded-down "small" cost. Verified byte-for-byte: real
`pyarrow.feather.read_table()` reads `raw_json` back and it matches the
source NDJSON line exactly, zero mismatches across all 562 Patient /
296,901 Observation / 19,571 Condition rows -- genuinely new verification
for this project, since neither fhir-arrow nor hl7-arrow had a
pyarrow-level fidelity check for a raw/verbatim column before this.

### Root-causing the "allocator overhead" bucket: a stale dependency, not `_extract_string`

The 24%→15.6% "allocator overhead" profiling bucket left unexplained back
at Phase G/Phase 2 was guessed to most likely be the original
`_extract_string` calls during shredding. That guess was already stale by
the time it was investigated further: Phase 2 (same session, earlier)
retired the entire row-based shredding path, and `_extract_string` is now
called from nowhere in production (`grep` confirms it — only
`test_fast_shred.mojo` still calls it directly). **Lesson applied, not
just stated**: didn't trust the old hypothesis, re-profiled the CURRENT
pipeline from scratch instead of chasing dead code.

A fresh `sample`-based profile (debug-symbol binary, 6-7 iterations over
the real 296,901-row Observation file, ~5,100-6,100 real work samples)
found something unrelated to allocator overhead at all: **`arrow.mojo`
itself accounted for ~46.8% of all real work** (`arrow.mojo:100` inside
`encode_ipc_message`'s body-byte-copy loop, `arrow.mojo:1141` inside
`decode_ipc_message` as called from `encode_arrow_file`'s footer-Block
construction). Root cause: this repo's `arrow` dependency was still
pinned to `>=1.1.2`, resolving to **1.1.3** -- which predates the
byte-by-byte IPC copy-loop fix that landed in `arrow` v1.2.1 during a
completely different investigation on hl7-arrow, this same session. Once
`raw_json` pushed this repo's own payload sizes into the same regime that
originally exposed that bug on hl7-arrow, the exact same latent
inefficiency became dominant here too -- a live example of the
`arrow`-side lesson stated back when that bug was first found: "a shared
dependency's own benchmarks are not sufficient evidence a hot path is
fast enough for every consumer," now proven true for a *second*,
independent consumer of the same dependency.

**Fix required zero new engineering** -- the bug was already found and
fixed upstream; this repo just hadn't picked up the release. Bumped the
`arrow` constraint to `>=1.2.2` (`mojo-pkg update`, `1.1.3 -> 1.2.2`).
Full suite green (`ndjson`/`fast_shred`/`fhir_arrow`, 33+ tests), real
pyarrow interop re-verified with zero mismatches across all rows.

**Real numbers, before/after, same regenerated Synthea dataset:**

| Resource | Before (arrow 1.1.3) | After (arrow 1.2.2) | Improvement |
|---|---|---|---|
| Patient | ~8.5 ms | ~6.1 ms | ~28% faster |
| Observation | ~1,853 ms | ~1,498 ms | ~19% faster |
| Condition | ~105 ms | ~75 ms | ~28% faster |

A follow-up profiling pass confirmed the mechanism directly, not just the
wall-clock number: `arrow.mojo`'s real contribution dropped from ~46.8%
to effectively **0%** (1 sample out of 5,142). What remains in the
profile now is legitimate, expected work with no single dominant
bottleneck -- `List.extend`'s inner copy loop (buffer growth, partly from
`raw_json`'s own bulk copies), `_skip_string`'s SIMD candidate scan (JSON
scanning, skipping fields this schema doesn't shred), the NDJSON file
read itself, and the shred call site -- the same shape of "real work,
properly distributed" outcome hl7-arrow's own profiling settled into
after its equivalent fix.

## Known limitations

- **Real `pyarrow`/DuckDB/Polars can now open the `.feather` files this
  produces** — verified directly against real Synthea Patient data (577
  rows, correct schema and values read back via `pyarrow.feather.
  read_table()`), not just this repo's own `decode_arrow_file`. This
  required three separate bug fixes upstream, in `arrow` (`>=1.1.1`) and
  its `flatbuffers` dependency (`>=1.1.1`): the trailing magic bytes
  (8 bytes written, spec requires 6), an inverted `soffset` sign
  convention in the FlatBuffers Footer encoding, and RecordBatch
  `Block.bodyLength` being computed from the wrong reference point. None
  of that code lived in this repo; bump the `arrow` dependency to pick up
  the fix.
- Only the fields listed above are individually shredded into typed
  columns; everything else is only available via the raw `raw_json`
  passthrough (see "Extra fields" above), not its own structured column --
  and that passthrough has a real, measured cost (roughly doubles
  wall-clock time per resource type), not a free addition.
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

- [arrow](https://github.com/Mosaad-M/arrow) `>=1.2.2`: pure-Mojo Arrow IPC
  encoder/decoder (pulls in `flatbuffers` transitively)

No `max` dependency: Phase D's parallel path investigated
`max.algorithm.parallelize` (see Benchmark → Phase D) but ended up not
using it — the shipped parallel path is process-level, driven entirely by
the shell (`bench/run_parallel_mojo.sh`) and this repo's own compiled
binaries, so `max` was removed from `pixi.toml` again once that was clear.

## License

MIT
