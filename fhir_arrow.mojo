# fhir_arrow.mojo: streaming column builders + Feather writers for shredded
# FHIR resources.
#
# Fuses field extraction with Arrow column-building: shred_*_fast_into_columns
# writes decoded bytes directly into a streaming column builder during the
# scan itself, instead of building a row struct with heap-allocated String
# fields that a separate transpose step later copies into column buffers.
# This replaced an earlier two-step design (shred -> row struct -> transpose
# -> build_*_column) once a real profiling gate confirmed it actually cuts
# allocator overhead: Patient shredding's allocator-overhead share (measured
# with the same macOS `sample`-based methodology used to find the original
# bottleneck) went from 9.9% to 4.7%, roughly halved, and Patient wall-clock
# went from 3.94ms to 3.37ms (~14% faster) on real Synthea data. The
# row-based path (PatientRow/ObservationRow/ConditionRow, shred_patient_fast/
# shred_observation_fast/shred_condition_fast, build_string_column et al.,
# and the *_to_record_batch transpose functions) has been retired now that
# all three resource types' fused paths are proven correct and are what
# production actually uses -- see git history for that code if it's ever
# needed as a reference.
#
# Uses arrow.mojo's legacy ArrowType/ArrowArray/RecordBatch/encode_arrow_file
# API (proven end-to-end by csv_arrow.mojo), not the newer Phase 1/2
# typed-builder API (dtypes/arrays/builders.mojo), which still has no bridge
# to file encoding.

from std.pathlib import Path
from arrow import (
    ArrowType, ArrowField, ArrowSchema, ArrowArray, RecordBatch,
    encode_arrow_file, decode_arrow_file, ArrowFileWriter,
)
from flatbuffers import write_i32_le, write_f64_le
from ndjson import (
    read_ndjson_lines,
    read_ndjson_range,
    _read_ndjson_range_spans,
    _find_next_line_boundary,
)
from fast_shred import (
    _find_keys, _find_key, _first_array_element, _coding0_at,
    _extract_bool, _extract_number, _decode_escaped_string_into,
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


# ── Streaming Arrow column builders ───────────────────────────────────────────
#
# append_json_string/append/append_null write directly into each builder's
# own growing buffer as each row is shredded -- no intermediate String or
# List[Optional[...]] per row. finish() produces the exact ArrowArray shape
# real Arrow expects, so nothing about schema/RecordBatch assembly or
# encode_arrow_file needed to change to adopt this.

comptime _FUSED_QUOTE = UInt8(34)      # '"'
comptime _FUSED_BACKSLASH = UInt8(92)  # '\'


struct StringColumnBuilder(Movable):
    """Streaming Utf8 Arrow column builder. append_json_string appends
    decoded bytes directly into this builder's own growing value buffer
    during shredding -- no intermediate String is ever allocated for the
    escape-free fast case (the common one), matching
    fast_shred._extract_string's fast/escaped-fallback split but writing
    straight into self.values instead of building a String only to have
    a separate step copy it again later."""

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

    def append_raw(mut self, b: Span[UInt8, _]) raises:
        """Appends `b` verbatim, byte-for-byte, with NO JSON-escape
        decoding -- unlike append_json_string, this is for a full raw
        record (raw_json), where decoding would be meaningless across the
        whole object's structural quotes/braces, not just a single
        field's value."""
        self.values.extend(b)
        self.null_bits.append(True)
        self.length += 1
        self._push_offset()

    def finish(deinit self) raises -> ArrowArray:
        var validity = List[UInt8]()
        if self.null_count > 0:
            validity = _pack_bits(self.null_bits)
        return ArrowArray(
            ArrowType.utf8(), self.length, self.null_count, validity^, self.offsets^, self.values^
        )


struct BoolColumnBuilder(Movable):
    """Streaming Bool Arrow column builder: packed bits, LSB-first."""

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

    def finish(deinit self) raises -> ArrowArray:
        var validity = List[UInt8]()
        if self.null_count > 0:
            validity = _pack_bits(self.null_bits)
        var value_bytes = _pack_bits(self.value_bits)
        return ArrowArray(
            ArrowType.bool_(), self.length, self.null_count, validity^, List[UInt8](), value_bytes^
        )


struct Float64ColumnBuilder(Movable):
    """Streaming Float64 Arrow column builder. Same pre-size-then-indexed-
    write shape as StringColumnBuilder's offsets (_push_value), not a
    per-byte append loop -- 8 zero bytes reserved then written in place."""

    var values: List[UInt8]
    var null_bits: List[Bool]
    var length: Int
    var null_count: Int

    def __init__(out self):
        self.values = List[UInt8]()
        self.null_bits = List[Bool]()
        self.length = 0
        self.null_count = 0

    def _push_value(mut self, val: Float64) raises:
        for _ in range(8):
            self.values.append(UInt8(0))
        write_f64_le(self.values, len(self.values) - 8, val)

    def append(mut self, val: Float64) raises:
        self._push_value(val)
        self.null_bits.append(True)
        self.length += 1

    def append_null(mut self) raises:
        self._push_value(Float64(0.0))
        self.null_bits.append(False)
        self.null_count += 1
        self.length += 1

    def finish(deinit self) raises -> ArrowArray:
        var validity = List[UInt8]()
        if self.null_count > 0:
            validity = _pack_bits(self.null_bits)
        return ArrowArray(
            ArrowType.float_(2), self.length, self.null_count, validity^, List[UInt8](), self.values^
        )


# ── Patient ────────────────────────────────────────────────────────────────────


struct PatientColumns(Movable):
    var id: StringColumnBuilder
    var gender: StringColumnBuilder
    var birth_date: StringColumnBuilder
    var family_name: StringColumnBuilder
    var given_name: StringColumnBuilder
    var deceased: BoolColumnBuilder
    var raw_json: StringColumnBuilder

    def __init__(out self):
        self.id = StringColumnBuilder()
        self.gender = StringColumnBuilder()
        self.birth_date = StringColumnBuilder()
        self.family_name = StringColumnBuilder()
        self.given_name = StringColumnBuilder()
        self.deceased = BoolColumnBuilder()
        self.raw_json = StringColumnBuilder()

    def finish(deinit self) raises -> RecordBatch:
        var n = self.id.length
        var arrays = List[ArrowArray]()
        arrays.append(self.id^.finish())
        arrays.append(self.gender^.finish())
        arrays.append(self.birth_date^.finish())
        arrays.append(self.family_name^.finish())
        arrays.append(self.given_name^.finish())
        arrays.append(self.deceased^.finish())
        arrays.append(self.raw_json^.finish())
        return RecordBatch(Int64(n), arrays^)


def shred_patient_fast_into_columns(
    b: Span[UInt8, _], mut columns: PatientColumns
) raises:
    """Field-finding logic identical to the retired shred_patient_fast
    (_find_keys/_first_array_element/_extract_bool, unchanged) -- only the
    destination of decoded values differs: appended directly into the
    passed-in column builders instead of constructing a row struct. Every
    column MUST get exactly one append/append_null call per invocation, in
    the same fixed order every time -- a missing call silently misaligns
    every subsequent row in that column relative to the others, the one
    new correctness risk this design introduces (tested explicitly in
    test_fhir_arrow.mojo's column-alignment tests, not just field-value
    checks)."""
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

    columns.raw_json.append_raw(b)


def patient_schema() -> ArrowSchema:
    var fields = List[ArrowField]()
    fields.append(ArrowField("id", ArrowType.utf8(), False))
    fields.append(ArrowField("gender", ArrowType.utf8(), True))
    fields.append(ArrowField("birth_date", ArrowType.utf8(), True))
    fields.append(ArrowField("family_name", ArrowType.utf8(), True))
    fields.append(ArrowField("given_name", ArrowType.utf8(), True))
    fields.append(ArrowField("deceased", ArrowType.bool_(), True))
    fields.append(ArrowField("raw_json", ArrowType.utf8(), False))
    return ArrowSchema(fields, Int16(0))


# ── Observation ──────────────────────────────────────────────────────────────


struct ObservationColumns(Movable):
    var id: StringColumnBuilder
    var patient_ref: StringColumnBuilder
    var code: StringColumnBuilder
    var code_system: StringColumnBuilder
    var code_display: StringColumnBuilder
    var status: StringColumnBuilder
    var effective_datetime: StringColumnBuilder
    var value_quantity: Float64ColumnBuilder
    var value_unit: StringColumnBuilder
    var value_string: StringColumnBuilder
    var raw_json: StringColumnBuilder

    def __init__(out self):
        self.id = StringColumnBuilder()
        self.patient_ref = StringColumnBuilder()
        self.code = StringColumnBuilder()
        self.code_system = StringColumnBuilder()
        self.code_display = StringColumnBuilder()
        self.status = StringColumnBuilder()
        self.effective_datetime = StringColumnBuilder()
        self.value_quantity = Float64ColumnBuilder()
        self.value_unit = StringColumnBuilder()
        self.value_string = StringColumnBuilder()
        self.raw_json = StringColumnBuilder()

    def finish(deinit self) raises -> RecordBatch:
        var n = self.id.length
        var arrays = List[ArrowArray]()
        arrays.append(self.id^.finish())
        arrays.append(self.patient_ref^.finish())
        arrays.append(self.code^.finish())
        arrays.append(self.code_system^.finish())
        arrays.append(self.code_display^.finish())
        arrays.append(self.status^.finish())
        arrays.append(self.effective_datetime^.finish())
        arrays.append(self.value_quantity^.finish())
        arrays.append(self.value_unit^.finish())
        arrays.append(self.value_string^.finish())
        arrays.append(self.raw_json^.finish())
        return RecordBatch(Int64(n), arrays^)


def shred_observation_fast_into_columns(
    b: Span[UInt8, _], mut columns: ObservationColumns
) raises:
    """Field-finding logic identical to the retired shred_observation_fast
    -- see shred_patient_fast_into_columns for the general design note."""
    var top_keys: List[String] = [
        "id", "subject", "code", "status", "effectiveDateTime",
        "valueQuantity", "valueString",
    ]
    var top = _find_keys(b, 0, top_keys)

    if not top[0]:
        raise Error("fhir_arrow: shred_observation_fast_into_columns: missing required field 'id'")
    columns.id.append_json_string(b, top[0].value())

    var ref_appended = False
    if top[1]:
        var ref_start = _find_key(b, top[1].value(), "reference")
        if ref_start:
            columns.patient_ref.append_json_string(b, ref_start.value())
            ref_appended = True
    if not ref_appended:
        columns.patient_ref.append_null()

    var code_appended = False
    var code_system_appended = False
    var code_display_appended = False
    if top[2]:
        var coding0_start = _coding0_at(b, top[2].value())
        if coding0_start:
            var coding_keys: List[String] = ["code", "system", "display"]
            var coding_fields = _find_keys(b, coding0_start.value(), coding_keys)
            if coding_fields[0]:
                columns.code.append_json_string(b, coding_fields[0].value())
                code_appended = True
            if coding_fields[1]:
                columns.code_system.append_json_string(b, coding_fields[1].value())
                code_system_appended = True
            if coding_fields[2]:
                columns.code_display.append_json_string(b, coding_fields[2].value())
                code_display_appended = True
    if not code_appended:
        columns.code.append_null()
    if not code_system_appended:
        columns.code_system.append_null()
    if not code_display_appended:
        columns.code_display.append_null()

    if top[3]:
        columns.status.append_json_string(b, top[3].value())
    else:
        columns.status.append_null()

    if top[4]:
        columns.effective_datetime.append_json_string(b, top[4].value())
    else:
        columns.effective_datetime.append_null()

    var vq_appended = False
    var vu_appended = False
    var vs_appended = False
    if top[5]:
        var vq_keys: List[String] = ["value", "unit"]
        var vq_fields = _find_keys(b, top[5].value(), vq_keys)
        if vq_fields[0]:
            columns.value_quantity.append(_extract_number(b, vq_fields[0].value()))
            vq_appended = True
        if vq_fields[1]:
            columns.value_unit.append_json_string(b, vq_fields[1].value())
            vu_appended = True
    elif top[6]:
        columns.value_string.append_json_string(b, top[6].value())
        vs_appended = True
    if not vq_appended:
        columns.value_quantity.append_null()
    if not vu_appended:
        columns.value_unit.append_null()
    if not vs_appended:
        columns.value_string.append_null()

    columns.raw_json.append_raw(b)


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
    fields.append(ArrowField("raw_json", ArrowType.utf8(), False))
    return ArrowSchema(fields, Int16(0))


# ── Condition ────────────────────────────────────────────────────────────────


struct ConditionColumns(Movable):
    var id: StringColumnBuilder
    var patient_ref: StringColumnBuilder
    var code: StringColumnBuilder
    var code_display: StringColumnBuilder
    var clinical_status: StringColumnBuilder
    var onset_datetime: StringColumnBuilder
    var recorded_date: StringColumnBuilder
    var raw_json: StringColumnBuilder

    def __init__(out self):
        self.id = StringColumnBuilder()
        self.patient_ref = StringColumnBuilder()
        self.code = StringColumnBuilder()
        self.code_display = StringColumnBuilder()
        self.clinical_status = StringColumnBuilder()
        self.onset_datetime = StringColumnBuilder()
        self.recorded_date = StringColumnBuilder()
        self.raw_json = StringColumnBuilder()

    def finish(deinit self) raises -> RecordBatch:
        var n = self.id.length
        var arrays = List[ArrowArray]()
        arrays.append(self.id^.finish())
        arrays.append(self.patient_ref^.finish())
        arrays.append(self.code^.finish())
        arrays.append(self.code_display^.finish())
        arrays.append(self.clinical_status^.finish())
        arrays.append(self.onset_datetime^.finish())
        arrays.append(self.recorded_date^.finish())
        arrays.append(self.raw_json^.finish())
        return RecordBatch(Int64(n), arrays^)


def shred_condition_fast_into_columns(
    b: Span[UInt8, _], mut columns: ConditionColumns
) raises:
    """Field-finding logic identical to the retired shred_condition_fast
    -- see shred_patient_fast_into_columns for the general design note."""
    var top_keys: List[String] = [
        "id", "subject", "code", "clinicalStatus", "onsetDateTime", "recordedDate",
    ]
    var top = _find_keys(b, 0, top_keys)

    if not top[0]:
        raise Error("fhir_arrow: shred_condition_fast_into_columns: missing required field 'id'")
    columns.id.append_json_string(b, top[0].value())

    var ref_appended = False
    if top[1]:
        var ref_start = _find_key(b, top[1].value(), "reference")
        if ref_start:
            columns.patient_ref.append_json_string(b, ref_start.value())
            ref_appended = True
    if not ref_appended:
        columns.patient_ref.append_null()

    var code_appended = False
    var code_display_appended = False
    if top[2]:
        var coding0_start = _coding0_at(b, top[2].value())
        if coding0_start:
            var coding_keys: List[String] = ["code", "display"]
            var coding_fields = _find_keys(b, coding0_start.value(), coding_keys)
            if coding_fields[0]:
                columns.code.append_json_string(b, coding_fields[0].value())
                code_appended = True
            if coding_fields[1]:
                columns.code_display.append_json_string(b, coding_fields[1].value())
                code_display_appended = True
    if not code_appended:
        columns.code.append_null()
    if not code_display_appended:
        columns.code_display.append_null()

    var cs_appended = False
    if top[3]:
        var cs_coding_start = _find_key(b, top[3].value(), "coding")
        if cs_coding_start:
            var cs0_start = _first_array_element(b, cs_coding_start.value())
            if cs0_start:
                var cs_code_field = _find_key(b, cs0_start.value(), "code")
                if cs_code_field:
                    columns.clinical_status.append_json_string(b, cs_code_field.value())
                    cs_appended = True
    if not cs_appended:
        columns.clinical_status.append_null()

    if top[4]:
        columns.onset_datetime.append_json_string(b, top[4].value())
    else:
        columns.onset_datetime.append_null()

    if top[5]:
        columns.recorded_date.append_json_string(b, top[5].value())
    else:
        columns.recorded_date.append_null()

    columns.raw_json.append_raw(b)


def condition_schema() -> ArrowSchema:
    var fields = List[ArrowField]()
    fields.append(ArrowField("id", ArrowType.utf8(), False))
    fields.append(ArrowField("patient_ref", ArrowType.utf8(), True))
    fields.append(ArrowField("code", ArrowType.utf8(), True))
    fields.append(ArrowField("code_display", ArrowType.utf8(), True))
    fields.append(ArrowField("clinical_status", ArrowType.utf8(), True))
    fields.append(ArrowField("onset_datetime", ArrowType.utf8(), True))
    fields.append(ArrowField("recorded_date", ArrowType.utf8(), True))
    fields.append(ArrowField("raw_json", ArrowType.utf8(), False))
    return ArrowSchema(fields, Int16(0))


# ── End-to-end orchestration ──────────────────────────────────────────────────


def _shred_patient_lines(b: Span[UInt8, _], spans: List[Tuple[Int, Int]]) raises -> RecordBatch:
    var columns = PatientColumns()
    for i in range(len(spans)):
        var span = spans[i]
        shred_patient_fast_into_columns(b[span[0] : span[1]], columns)
    return columns^.finish()


def _shred_observation_lines(b: Span[UInt8, _], spans: List[Tuple[Int, Int]]) raises -> RecordBatch:
    var columns = ObservationColumns()
    for i in range(len(spans)):
        var span = spans[i]
        shred_observation_fast_into_columns(b[span[0] : span[1]], columns)
    return columns^.finish()


def _shred_condition_lines(b: Span[UInt8, _], spans: List[Tuple[Int, Int]]) raises -> RecordBatch:
    var columns = ConditionColumns()
    for i in range(len(spans)):
        var span = spans[i]
        shred_condition_fast_into_columns(b[span[0] : span[1]], columns)
    return columns^.finish()


def _schema_for_kind(kind: String, caller: String) raises -> ArrowSchema:
    """The output schema for a resource kind; also the single place an
    unknown kind is rejected, before any input is read or output created."""
    if kind == "Patient":
        return patient_schema()
    elif kind == "Observation":
        return observation_schema()
    elif kind == "Condition":
        return condition_schema()
    raise Error(
        "fhir_arrow: "
        + caller
        + ": unknown resource kind '"
        + kind
        + "' (expected Patient, Observation, or Condition)"
    )


def _shred_lines_for_kind(
    b: Span[UInt8, _], spans: List[Tuple[Int, Int]], kind: String
) raises -> RecordBatch:
    """Dispatch to the per-kind shredder. `kind` must already have been
    validated by _schema_for_kind."""
    if kind == "Patient":
        return _shred_patient_lines(b, spans)
    elif kind == "Observation":
        return _shred_observation_lines(b, spans)
    return _shred_condition_lines(b, spans)


def ndjson_to_feather(ndjson_path: String, out_path: String, kind: String) raises:
    """Read a Bulk FHIR NDJSON export file of one resource type and write a
    Feather file of its shredded columns. `kind` is one of "Patient",
    "Observation", "Condition". Uses the zero-tree fast_shred scanning
    primitives, fused directly into Arrow column builders: raw lines are
    never parsed into a JsonValue tree, and no per-field String or row
    struct is ever allocated -- only the specific fields each schema needs
    are ever decoded, straight into their column's buffer. The file is
    read once into one buffer; each record is shredded directly from a
    byte-span slice of that buffer."""
    var result = read_ndjson_lines(ndjson_path)
    var content = result[0]
    var spans = result[1].copy()
    var b = content.as_bytes()

    var schema = _schema_for_kind(kind, "ndjson_to_feather")
    var batches = List[RecordBatch]()
    batches.append(_shred_lines_for_kind(b, spans, kind))
    Path(out_path).write_bytes(encode_arrow_file(schema, batches))


def ndjson_range_to_feather(
    ndjson_path: String, out_path: String, kind: String, start_byte: Int, end_byte: Int
) raises:
    """Same as ndjson_to_feather, but reads only the byte range [start_byte,
    end_byte) of the file (via read_ndjson_range: seek+read, not a whole-file
    read) and shreds just the lines found in it. Used by the parallel path:
    one process per byte-range chunk (boundaries computed once, up front, by
    chunk_planner.mojo -- NOT recomputed per worker), each producing its own
    Feather file, later combined by merge_feathers into one file with
    multiple RecordBatches (row order preserved by chunk order)."""
    var result = read_ndjson_range(ndjson_path, start_byte, end_byte)
    var content = result[0]
    var spans = result[1].copy()
    var b = content.as_bytes()

    var schema = _schema_for_kind(kind, "ndjson_range_to_feather")
    var batches = List[RecordBatch]()
    batches.append(_shred_lines_for_kind(b, spans, kind))
    Path(out_path).write_bytes(encode_arrow_file(schema, batches))


def ndjson_to_feather_streaming(
    ndjson_path: String,
    out_path: String,
    kind: String,
    max_chunk_bytes: Int = 1024 * 1024,
) raises:
    """Same output as ndjson_to_feather (same rows, same order), but in
    memory bounded by `max_chunk_bytes` rather than by the file size. Reads
    the file one chunk at a time, each chunk extended to the next line
    boundary via _find_next_line_boundary so no record is split, shreds it,
    and appends it as one RecordBatch straight to `out_path` via
    ArrowFileWriter. Nothing from earlier chunks stays resident except the
    footer's 24 bytes per written batch.

    A single line longer than max_chunk_bytes is still read whole, so the
    real bound is max(max_chunk_bytes, longest line). The output holds one
    RecordBatch per non-blank chunk instead of ndjson_to_feather's single
    batch; Arrow readers see the same table either way."""
    if max_chunk_bytes <= 0:
        raise Error(
            "fhir_arrow: ndjson_to_feather_streaming: max_chunk_bytes must be positive"
        )
    var schema = _schema_for_kind(kind, "ndjson_to_feather_streaming")

    var f = open(ndjson_path, "r")
    var file_size = Int(f.seek(0, 2))
    f.close()

    var writer = ArrowFileWriter(out_path, schema)
    var start = 0
    var records_seen = 0
    while start < file_size:
        # Scanning from target - 1 (not target) keeps a chunk that already
        # ends exactly on a newline as-is instead of pulling in the next line.
        var end = file_size
        if start + max_chunk_bytes < file_size:
            end = _find_next_line_boundary(ndjson_path, start + max_chunk_bytes - 1)

        var result = _read_ndjson_range_spans(ndjson_path, start, end)
        var spans = result[1].copy()
        if len(spans) > 0:
            writer.write_batch(_shred_lines_for_kind(result[0].as_bytes(), spans, kind))
            records_seen += len(spans)
        start = end
    writer.finish()

    # Checked after finish() so the output file is never left truncated;
    # matches ndjson_to_feather's "no records" error.
    if records_seen == 0:
        raise Error(
            "fhir_arrow: ndjson_to_feather_streaming: no records found in " + ndjson_path
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
