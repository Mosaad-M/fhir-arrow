# fhir_arrow.mojo: column builders + Feather writers for shredded FHIR rows.
#
# Uses arrow.mojo's legacy ArrowType/ArrowField/ArrowSchema/ArrowArray/
# RecordBatch/encode_arrow_file API (proven end-to-end by csv_arrow.mojo),
# not the newer Phase 1/2 typed-builder API (dtypes/arrays/builders.mojo),
# which has no bridge to file encoding yet.

from std.pathlib import Path
from arrow import (
    ArrowType, ArrowField, ArrowSchema, ArrowArray, RecordBatch,
    encode_arrow_file, decode_arrow_file,
)
from flatbuffers import write_i32_le, write_f64_le
from ndjson import read_ndjson_lines, read_ndjson_range
from resources import PatientRow, ObservationRow, ConditionRow
from fast_shred import (
    shred_patient_fast, shred_observation_fast, shred_condition_fast,
    _find_keys, _first_array_element, _extract_bool, _decode_escaped_string_into,
)


# ── Bit packing (shared by validity bitmaps and Bool value buffers: both are
#    packed 1 bit/element, LSB-first, per Arrow's format) ────────────────────


def _pack_bits(bits: List[Bool]) -> List[UInt8]:
    var length = len(bits)
    var n_bytes = (length + 7) // 8
    var packed = List[UInt8]()
    for _ in range(n_bytes):
        packed.append(UInt8(0))
    for i in range(length):
        if bits[i]:
            packed[i // 8] = packed[i // 8] | (UInt8(1) << UInt8(i % 8))
    return packed^


# ── Column builders ───────────────────────────────────────────────────────────


def build_string_column(values: List[Optional[String]]) raises -> ArrowArray:
    """Nullable Utf8 column from a list of optional strings.

    value_bytes is pre-sized once (total byte length computed up front)
    and filled via indexed writes rather than growing via `.append()` in
    a loop: the fix for the buffer-growth cost the v0 benchmark
    identified as one of the two dominant slowdowns versus Python."""
    var length = len(values)
    var null_bits = List[Bool](capacity=length)
    var null_count = 0
    var total_bytes = 0
    for i in range(length):
        if values[i]:
            null_bits.append(True)
            total_bytes += len(values[i].value().as_bytes())
        else:
            null_bits.append(False)
            null_count += 1

    var validity = List[UInt8]()
    if null_count > 0:
        validity = _pack_bits(null_bits)

    var offsets = List[UInt8]()
    for _ in range((length + 1) * 4):
        offsets.append(UInt8(0))
    write_i32_le(offsets, 0, Int32(0))

    var value_bytes = List[UInt8]()
    for _ in range(total_bytes):
        value_bytes.append(UInt8(0))

    var cur = 0
    for i in range(length):
        if values[i]:
            var sb = values[i].value().as_bytes()
            var n = len(sb)
            for j in range(n):
                value_bytes[cur + j] = sb[j]
            cur += n
        write_i32_le(offsets, (i + 1) * 4, Int32(cur))

    return ArrowArray(
        ArrowType.utf8(), length, null_count, validity, offsets, value_bytes
    )


def build_required_string_column(values: List[String]) raises -> ArrowArray:
    """Non-nullable Utf8 column (used for `id`, which is always required)."""
    var opt_values = List[Optional[String]]()
    for i in range(len(values)):
        opt_values.append(Optional[String](values[i]))
    return build_string_column(opt_values)


def build_float64_column(values: List[Optional[Float64]]) raises -> ArrowArray:
    """Nullable Float64 column from a list of optional floats.

    null_bits is capacity-reserved up front (length is known before the
    loop starts), so the `.append()` loop below never triggers a
    reallocation: the same buffer-growth fix already applied to
    build_string_column's value bytes, applied here to the bitmap-source
    list instead."""
    var length = len(values)
    var null_bits = List[Bool](capacity=length)
    var null_count = 0
    for i in range(length):
        if values[i]:
            null_bits.append(True)
        else:
            null_bits.append(False)
            null_count += 1

    var validity = List[UInt8]()
    if null_count > 0:
        validity = _pack_bits(null_bits)

    var value_bytes = List[UInt8]()
    for _ in range(length * 8):
        value_bytes.append(UInt8(0))
    for i in range(length):
        var f = Float64(0.0)
        if values[i]:
            f = values[i].value()
        write_f64_le(value_bytes, i * 8, f)

    return ArrowArray(
        ArrowType.float_(2), length, null_count, validity, List[UInt8](), value_bytes
    )


def build_bool_column(values: List[Optional[Bool]]) raises -> ArrowArray:
    """Nullable Bool column. Values buffer is packed bits, LSB-first (same
    scheme as the validity bitmap, per arrow.mojo's decode/encode).
    Both bit-source lists are capacity-reserved up front, same reasoning
    as build_float64_column's null_bits."""
    var length = len(values)
    var null_bits = List[Bool](capacity=length)
    var value_bits = List[Bool](capacity=length)
    var null_count = 0
    for i in range(length):
        if values[i]:
            null_bits.append(True)
            value_bits.append(values[i].value())
        else:
            null_bits.append(False)
            value_bits.append(False)
            null_count += 1

    var validity = List[UInt8]()
    if null_count > 0:
        validity = _pack_bits(null_bits)

    var value_bytes = _pack_bits(value_bits)

    return ArrowArray(
        ArrowType.bool_(), length, null_count, validity, List[UInt8](), value_bytes
    )


# ── Patient: schema + RecordBatch assembly ───────────────────────────────────


# ── Phase 1 prototype: fuse extraction with column-building (Patient only) ───
#
# The row-based path above (shred_patient_fast -> PatientRow -> into_parts()
# -> build_string_column) still allocates one String per string field per
# row during shredding, even after the transpose-copy fix removed the
# second copy. This prototype writes decoded bytes directly into a
# streaming Arrow column builder during the scan itself, skipping the
# per-field String entirely for the common (escape-free) case. Kept
# side-by-side with shred_patient_fast/patients_to_record_batch, which
# stay untouched as the correctness oracle for this phase -- not wired
# into ndjson_to_feather yet, pending the real-profiling gate check this
# phase exists to run.

comptime _FUSED_QUOTE = UInt8(34)      # '"'
comptime _FUSED_BACKSLASH = UInt8(92)  # '\'


struct StringColumnBuilder(Movable):
    """Streaming Utf8 Arrow column builder. append_json_string appends
    decoded bytes directly into this builder's own growing value buffer
    during shredding -- no intermediate String is ever allocated for the
    escape-free fast case (the common one), matching
    fast_shred._extract_string's fast/escaped-fallback split but writing
    straight into self.values instead of building a String only to have
    build_string_column copy it again later. finish() produces the exact
    ArrowArray shape build_string_column already produces, so nothing
    downstream (schema, RecordBatch, encode_arrow_file) needs to change."""

    var values: List[UInt8]
    var offsets: List[UInt8]
    var null_bits: List[Bool]
    var length: Int
    var null_count: Int

    def __init__(out self):
        self.values = List[UInt8]()
        self.offsets = List[UInt8]()
        for _ in range(4):
            self.offsets.append(UInt8(0))  # offsets[0] = 0
        self.null_bits = List[Bool]()
        self.length = 0
        self.null_count = 0

    def _push_offset(mut self) raises:
        for _ in range(4):
            self.offsets.append(UInt8(0))
        write_i32_le(self.offsets, len(self.offsets) - 4, Int32(len(self.values)))

    def append_json_string(mut self, b: Span[UInt8, _], start: Int) raises:
        """start must point at the opening quote of a JSON string value."""
        var n = len(b)
        var j = start + 1
        while j < n:
            var c = b[j]
            if c == _FUSED_QUOTE:
                self.values.extend(b[start + 1 : j])
                self.null_bits.append(True)
                self.length += 1
                self._push_offset()
                return
            elif c == _FUSED_BACKSLASH:
                _ = _decode_escaped_string_into(b, start, self.values)
                self.null_bits.append(True)
                self.length += 1
                self._push_offset()
                return
            j += 1
        raise Error("fhir_arrow: StringColumnBuilder: unterminated string")

    def append_null(mut self) raises:
        self.null_bits.append(False)
        self.null_count += 1
        self.length += 1
        self._push_offset()

    def finish(deinit self) raises -> ArrowArray:
        var validity = List[UInt8]()
        if self.null_count > 0:
            validity = _pack_bits(self.null_bits)
        return ArrowArray(
            ArrowType.utf8(), self.length, self.null_count, validity, self.offsets^, self.values^
        )


struct BoolColumnBuilder(Movable):
    """Streaming Bool Arrow column builder, same packed-bits shape
    build_bool_column already produces."""

    var null_bits: List[Bool]
    var value_bits: List[Bool]
    var length: Int
    var null_count: Int

    def __init__(out self):
        self.null_bits = List[Bool]()
        self.value_bits = List[Bool]()
        self.length = 0
        self.null_count = 0

    def append(mut self, val: Bool) raises:
        self.null_bits.append(True)
        self.value_bits.append(val)
        self.length += 1

    def append_null(mut self) raises:
        self.null_bits.append(False)
        self.value_bits.append(False)
        self.null_count += 1
        self.length += 1

    def finish(mut self) raises -> ArrowArray:
        var validity = List[UInt8]()
        if self.null_count > 0:
            validity = _pack_bits(self.null_bits)
        var value_bytes = _pack_bits(self.value_bits)
        return ArrowArray(
            ArrowType.bool_(), self.length, self.null_count, validity, List[UInt8](), value_bytes
        )


struct PatientColumns(Movable):
    var id: StringColumnBuilder
    var gender: StringColumnBuilder
    var birth_date: StringColumnBuilder
    var family_name: StringColumnBuilder
    var given_name: StringColumnBuilder
    var deceased: BoolColumnBuilder

    def __init__(out self):
        self.id = StringColumnBuilder()
        self.gender = StringColumnBuilder()
        self.birth_date = StringColumnBuilder()
        self.family_name = StringColumnBuilder()
        self.given_name = StringColumnBuilder()
        self.deceased = BoolColumnBuilder()

    def finish(deinit self) raises -> RecordBatch:
        var n = self.id.length
        var arrays = List[ArrowArray]()
        arrays.append(self.id^.finish())
        arrays.append(self.gender^.finish())
        arrays.append(self.birth_date^.finish())
        arrays.append(self.family_name^.finish())
        arrays.append(self.given_name^.finish())
        arrays.append(self.deceased.finish())
        return RecordBatch(Int64(n), arrays)


def shred_patient_fast_into_columns(
    b: Span[UInt8, _], mut columns: PatientColumns
) raises:
    """Fused equivalent of fast_shred.shred_patient_fast: identical
    field-finding logic (_find_keys/_first_array_element/_extract_bool,
    unchanged), but appends decoded values directly into the passed-in
    column builders instead of constructing a PatientRow. Every column
    MUST get exactly one append/append_null call per invocation, in the
    same fixed order every time -- a missing call silently misaligns
    every subsequent row in that column relative to the others, which is
    the one new correctness risk this design introduces (tested
    explicitly in test_fhir_arrow.mojo, not just field-value checks)."""
    var top_keys: List[String] = ["id", "gender", "birthDate", "name", "deceasedBoolean"]
    var top = _find_keys(b, 0, top_keys)

    if not top[0]:
        raise Error("fhir_arrow: shred_patient_fast_into_columns: missing required field 'id'")
    columns.id.append_json_string(b, top[0].value())

    if top[1]:
        columns.gender.append_json_string(b, top[1].value())
    else:
        columns.gender.append_null()

    if top[2]:
        columns.birth_date.append_json_string(b, top[2].value())
    else:
        columns.birth_date.append_null()

    var family_appended = False
    var given_appended = False
    if top[3]:
        var name0_start = _first_array_element(b, top[3].value())
        if name0_start:
            var name_keys: List[String] = ["family", "given"]
            var name_fields = _find_keys(b, name0_start.value(), name_keys)
            if name_fields[0]:
                columns.family_name.append_json_string(b, name_fields[0].value())
                family_appended = True
            if name_fields[1]:
                var given0_start = _first_array_element(b, name_fields[1].value())
                if given0_start:
                    columns.given_name.append_json_string(b, given0_start.value())
                    given_appended = True
    if not family_appended:
        columns.family_name.append_null()
    if not given_appended:
        columns.given_name.append_null()

    if top[4]:
        columns.deceased.append(_extract_bool(b, top[4].value()))
    else:
        columns.deceased.append_null()


def patients_to_feather_fused(ndjson_path: String, out_path: String) raises:
    """Same output as patients_to_feather(shred_patient_fast(...)), but via
    the fused columns-write path above. No .pop()/reverse dance needed --
    lines are iterated in original order and appended directly in that
    order, so there's no separate row-to-column transpose step left to
    get backwards."""
    var result = read_ndjson_lines(ndjson_path)
    var content = result[0]
    var spans = result[1].copy()
    var b = content.as_bytes()

    var columns = PatientColumns()
    for i in range(len(spans)):
        var span = spans[i]
        shred_patient_fast_into_columns(b[span[0] : span[1]], columns)

    var schema = patient_schema()
    var batch = columns^.finish()
    var batches = List[RecordBatch]()
    batches.append(batch^)
    var file_bytes = encode_arrow_file(schema, batches)
    Path(out_path).write_bytes(file_bytes)


def patient_schema() -> ArrowSchema:
    var fields = List[ArrowField]()
    fields.append(ArrowField("id", ArrowType.utf8(), False))
    fields.append(ArrowField("gender", ArrowType.utf8(), True))
    fields.append(ArrowField("birth_date", ArrowType.utf8(), True))
    fields.append(ArrowField("family_name", ArrowType.utf8(), True))
    fields.append(ArrowField("given_name", ArrowType.utf8(), True))
    fields.append(ArrowField("deceased", ArrowType.bool_(), True))
    return ArrowSchema(fields, Int16(0))


def patients_to_record_batch(var rows: List[PatientRow]) raises -> RecordBatch:
    """Consumes `rows`: moves each field out via into_parts() instead of
    copying it out of a borrowed reference, since every field was already
    allocated once during shredding -- a second copy here would double
    the allocation cost for no reason. `.pop()` consumes from the back,
    so columns are built in reverse row order and then reversed once
    each before use (single O(n) pass per column, not per-element)."""
    var n = len(rows)
    var ids = List[String](capacity=n)
    var genders = List[Optional[String]](capacity=n)
    var birth_dates = List[Optional[String]](capacity=n)
    var family_names = List[Optional[String]](capacity=n)
    var given_names = List[Optional[String]](capacity=n)
    var deceased = List[Optional[Bool]](capacity=n)
    while len(rows) > 0:
        var row = rows.pop()
        var parts = row^.into_parts()
        ids.append(parts[0])
        genders.append(parts[1])
        birth_dates.append(parts[2])
        family_names.append(parts[3])
        given_names.append(parts[4])
        deceased.append(parts[5])
    ids.reverse()
    genders.reverse()
    birth_dates.reverse()
    family_names.reverse()
    given_names.reverse()
    deceased.reverse()

    var arrays = List[ArrowArray]()
    arrays.append(build_required_string_column(ids))
    arrays.append(build_string_column(genders))
    arrays.append(build_string_column(birth_dates))
    arrays.append(build_string_column(family_names))
    arrays.append(build_string_column(given_names))
    arrays.append(build_bool_column(deceased))
    return RecordBatch(Int64(n), arrays)


def patients_to_feather(var rows: List[PatientRow], path: String) raises:
    var schema = patient_schema()
    var batch = patients_to_record_batch(rows^)
    var batches = List[RecordBatch]()
    batches.append(batch^)
    var file_bytes = encode_arrow_file(schema, batches)
    Path(path).write_bytes(file_bytes)


# ── Observation: schema + RecordBatch assembly ───────────────────────────────


def observation_schema() -> ArrowSchema:
    var fields = List[ArrowField]()
    fields.append(ArrowField("id", ArrowType.utf8(), False))
    fields.append(ArrowField("patient_ref", ArrowType.utf8(), True))
    fields.append(ArrowField("code", ArrowType.utf8(), True))
    fields.append(ArrowField("code_system", ArrowType.utf8(), True))
    fields.append(ArrowField("code_display", ArrowType.utf8(), True))
    fields.append(ArrowField("status", ArrowType.utf8(), True))
    fields.append(ArrowField("effective_datetime", ArrowType.utf8(), True))
    fields.append(ArrowField("value_quantity", ArrowType.float_(2), True))
    fields.append(ArrowField("value_unit", ArrowType.utf8(), True))
    fields.append(ArrowField("value_string", ArrowType.utf8(), True))
    return ArrowSchema(fields, Int16(0))


def observations_to_record_batch(var rows: List[ObservationRow]) raises -> RecordBatch:
    """Consumes `rows` -- see patients_to_record_batch for why (avoids a
    second copy of every already-allocated field)."""
    var n = len(rows)
    var ids = List[String](capacity=n)
    var patient_refs = List[Optional[String]](capacity=n)
    var codes = List[Optional[String]](capacity=n)
    var code_systems = List[Optional[String]](capacity=n)
    var code_displays = List[Optional[String]](capacity=n)
    var statuses = List[Optional[String]](capacity=n)
    var effective_datetimes = List[Optional[String]](capacity=n)
    var value_quantities = List[Optional[Float64]](capacity=n)
    var value_units = List[Optional[String]](capacity=n)
    var value_strings = List[Optional[String]](capacity=n)
    while len(rows) > 0:
        var row = rows.pop()
        var parts = row^.into_parts()
        ids.append(parts[0])
        patient_refs.append(parts[1])
        codes.append(parts[2])
        code_systems.append(parts[3])
        code_displays.append(parts[4])
        statuses.append(parts[5])
        effective_datetimes.append(parts[6])
        value_quantities.append(parts[7])
        value_units.append(parts[8])
        value_strings.append(parts[9])
    ids.reverse()
    patient_refs.reverse()
    codes.reverse()
    code_systems.reverse()
    code_displays.reverse()
    statuses.reverse()
    effective_datetimes.reverse()
    value_quantities.reverse()
    value_units.reverse()
    value_strings.reverse()

    var arrays = List[ArrowArray]()
    arrays.append(build_required_string_column(ids))
    arrays.append(build_string_column(patient_refs))
    arrays.append(build_string_column(codes))
    arrays.append(build_string_column(code_systems))
    arrays.append(build_string_column(code_displays))
    arrays.append(build_string_column(statuses))
    arrays.append(build_string_column(effective_datetimes))
    arrays.append(build_float64_column(value_quantities))
    arrays.append(build_string_column(value_units))
    arrays.append(build_string_column(value_strings))
    return RecordBatch(Int64(n), arrays)


def observations_to_feather(var rows: List[ObservationRow], path: String) raises:
    var schema = observation_schema()
    var batch = observations_to_record_batch(rows^)
    var batches = List[RecordBatch]()
    batches.append(batch^)
    var file_bytes = encode_arrow_file(schema, batches)
    Path(path).write_bytes(file_bytes)


# ── Condition: schema + RecordBatch assembly ─────────────────────────────────


def condition_schema() -> ArrowSchema:
    var fields = List[ArrowField]()
    fields.append(ArrowField("id", ArrowType.utf8(), False))
    fields.append(ArrowField("patient_ref", ArrowType.utf8(), True))
    fields.append(ArrowField("code", ArrowType.utf8(), True))
    fields.append(ArrowField("code_display", ArrowType.utf8(), True))
    fields.append(ArrowField("clinical_status", ArrowType.utf8(), True))
    fields.append(ArrowField("onset_datetime", ArrowType.utf8(), True))
    fields.append(ArrowField("recorded_date", ArrowType.utf8(), True))
    return ArrowSchema(fields, Int16(0))


def conditions_to_record_batch(var rows: List[ConditionRow]) raises -> RecordBatch:
    """Consumes `rows` -- see patients_to_record_batch for why (avoids a
    second copy of every already-allocated field)."""
    var n = len(rows)
    var ids = List[String](capacity=n)
    var patient_refs = List[Optional[String]](capacity=n)
    var codes = List[Optional[String]](capacity=n)
    var code_displays = List[Optional[String]](capacity=n)
    var clinical_statuses = List[Optional[String]](capacity=n)
    var onset_datetimes = List[Optional[String]](capacity=n)
    var recorded_dates = List[Optional[String]](capacity=n)
    while len(rows) > 0:
        var row = rows.pop()
        var parts = row^.into_parts()
        ids.append(parts[0])
        patient_refs.append(parts[1])
        codes.append(parts[2])
        code_displays.append(parts[3])
        clinical_statuses.append(parts[4])
        onset_datetimes.append(parts[5])
        recorded_dates.append(parts[6])
    ids.reverse()
    patient_refs.reverse()
    codes.reverse()
    code_displays.reverse()
    clinical_statuses.reverse()
    onset_datetimes.reverse()
    recorded_dates.reverse()

    var arrays = List[ArrowArray]()
    arrays.append(build_required_string_column(ids))
    arrays.append(build_string_column(patient_refs))
    arrays.append(build_string_column(codes))
    arrays.append(build_string_column(code_displays))
    arrays.append(build_string_column(clinical_statuses))
    arrays.append(build_string_column(onset_datetimes))
    arrays.append(build_string_column(recorded_dates))
    return RecordBatch(Int64(n), arrays)


def conditions_to_feather(var rows: List[ConditionRow], path: String) raises:
    var schema = condition_schema()
    var batch = conditions_to_record_batch(rows^)
    var batches = List[RecordBatch]()
    batches.append(batch^)
    var file_bytes = encode_arrow_file(schema, batches)
    Path(path).write_bytes(file_bytes)


# ── End-to-end orchestration ──────────────────────────────────────────────────


def ndjson_to_feather(ndjson_path: String, out_path: String, kind: String) raises:
    """Read a Bulk FHIR NDJSON export file of one resource type and write a
    Feather file of its shredded columns. `kind` is one of "Patient",
    "Observation", "Condition". Uses the zero-tree fast_shred path: raw
    lines are never parsed into a JsonValue tree, only the specific fields
    each row struct needs are ever decoded. The file is read once into one
    buffer; each record is shredded directly from a byte-span slice of
    that buffer, with no per-line String allocated to read it."""
    var result = read_ndjson_lines(ndjson_path)
    var content = result[0]
    var spans = result[1].copy()
    var b = content.as_bytes()

    if kind == "Patient":
        var rows = List[PatientRow](capacity=len(spans))
        for i in range(len(spans)):
            var span = spans[i]
            rows.append(shred_patient_fast(b[span[0] : span[1]]))
        patients_to_feather(rows^, out_path)
    elif kind == "Observation":
        var rows = List[ObservationRow](capacity=len(spans))
        for i in range(len(spans)):
            var span = spans[i]
            rows.append(shred_observation_fast(b[span[0] : span[1]]))
        observations_to_feather(rows^, out_path)
    elif kind == "Condition":
        var rows = List[ConditionRow](capacity=len(spans))
        for i in range(len(spans)):
            var span = spans[i]
            rows.append(shred_condition_fast(b[span[0] : span[1]]))
        conditions_to_feather(rows^, out_path)
    else:
        raise Error(
            "fhir_arrow: ndjson_to_feather: unknown resource kind '"
            + kind
            + "' (expected Patient, Observation, or Condition)"
        )


def ndjson_range_to_feather(
    ndjson_path: String, out_path: String, kind: String, start_byte: Int, end_byte: Int
) raises:
    """Same as ndjson_to_feather, but reads only the byte range [start_byte,
    end_byte) of the file (via read_ndjson_range: seek+read, not a whole-file
    read) and shreds just the lines found in it. Used by the parallel path:
    one process per byte-range chunk (boundaries computed once, up front, by
    chunk_planner.mojo -- NOT recomputed per worker), each producing its own
    Feather file, later combined by merge_feathers into one file with
    multiple RecordBatches (row order preserved by chunk order).

    An earlier version of this function took a (start_idx, end_idx) row-index
    range into the FULL file's span list, which required every worker to
    read_ndjson_lines the WHOLE file to compute that list -- measured
    directly: 8 workers each redundantly paying the full-file read+scan cost
    made an 8-worker Observation run slower than sequential (4748ms vs
    2132ms). This byte-range version is what actually gets each worker's
    cost to scale with its own chunk size instead of the whole file."""
    var result = read_ndjson_range(ndjson_path, start_byte, end_byte)
    var content = result[0]
    var spans = result[1].copy()
    var b = content.as_bytes()

    if kind == "Patient":
        var rows = List[PatientRow](capacity=len(spans))
        for i in range(len(spans)):
            var span = spans[i]
            rows.append(shred_patient_fast(b[span[0] : span[1]]))
        patients_to_feather(rows^, out_path)
    elif kind == "Observation":
        var rows = List[ObservationRow](capacity=len(spans))
        for i in range(len(spans)):
            var span = spans[i]
            rows.append(shred_observation_fast(b[span[0] : span[1]]))
        observations_to_feather(rows^, out_path)
    elif kind == "Condition":
        var rows = List[ConditionRow](capacity=len(spans))
        for i in range(len(spans)):
            var span = spans[i]
            rows.append(shred_condition_fast(b[span[0] : span[1]]))
        conditions_to_feather(rows^, out_path)
    else:
        raise Error(
            "fhir_arrow: ndjson_range_to_feather: unknown resource kind '"
            + kind
            + "' (expected Patient, Observation, or Condition)"
        )


def merge_feathers(paths: List[String], out_path: String) raises:
    """Combine N Feather files (same schema, produced by ndjson_range_to_feather
    for consecutive, ordered chunks) into ONE Feather file containing all of
    their RecordBatches, in the same order as `paths`. Arrow's IPC file
    format natively supports multiple RecordBatches per file, so this is a
    concatenation of batches, not a byte-level merge or a re-shred: each
    chunk file is decoded once and its batches are carried over unchanged."""
    if len(paths) == 0:
        raise Error("fhir_arrow: merge_feathers: no input paths given")

    var first_bytes = Path(paths[0]).read_bytes()
    var first_result = decode_arrow_file(first_bytes)
    var schema = first_result[0].copy()
    var all_batches = List[RecordBatch]()
    for b in first_result[1].copy():
        all_batches.append(b.copy())

    for i in range(1, len(paths)):
        var file_bytes = Path(paths[i]).read_bytes()
        var result = decode_arrow_file(file_bytes)
        for b in result[1].copy():
            all_batches.append(b.copy())

    var merged_bytes = encode_arrow_file(schema, all_batches)
    Path(out_path).write_bytes(merged_bytes)
