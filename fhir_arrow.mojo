# fhir_arrow.mojo: column builders + Feather writers for shredded FHIR rows.
#
# Uses arrow.mojo's legacy ArrowType/ArrowField/ArrowSchema/ArrowArray/
# RecordBatch/encode_arrow_file API (proven end-to-end by csv_arrow.mojo),
# not the newer Phase 1/2 typed-builder API (dtypes/arrays/builders.mojo),
# which has no bridge to file encoding yet.

from std.pathlib import Path
from arrow import (
    ArrowType, ArrowField, ArrowSchema, ArrowArray, RecordBatch,
    encode_arrow_file,
)
from flatbuffers import write_i32_le, write_f64_le
from ndjson import read_ndjson_lines
from resources import PatientRow, ObservationRow, ConditionRow
from fast_shred import (
    shred_patient_fast, shred_observation_fast, shred_condition_fast,
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


def patient_schema() -> ArrowSchema:
    var fields = List[ArrowField]()
    fields.append(ArrowField("id", ArrowType.utf8(), False))
    fields.append(ArrowField("gender", ArrowType.utf8(), True))
    fields.append(ArrowField("birth_date", ArrowType.utf8(), True))
    fields.append(ArrowField("family_name", ArrowType.utf8(), True))
    fields.append(ArrowField("given_name", ArrowType.utf8(), True))
    fields.append(ArrowField("deceased", ArrowType.bool_(), True))
    return ArrowSchema(fields, Int16(0))


def patients_to_record_batch(rows: List[PatientRow]) raises -> RecordBatch:
    var n = len(rows)
    var ids = List[String](capacity=n)
    var genders = List[Optional[String]](capacity=n)
    var birth_dates = List[Optional[String]](capacity=n)
    var family_names = List[Optional[String]](capacity=n)
    var given_names = List[Optional[String]](capacity=n)
    var deceased = List[Optional[Bool]](capacity=n)
    for i in range(len(rows)):
        ids.append(rows[i].id)
        genders.append(rows[i].gender)
        birth_dates.append(rows[i].birth_date)
        family_names.append(rows[i].family_name)
        given_names.append(rows[i].given_name)
        deceased.append(rows[i].deceased)

    var arrays = List[ArrowArray]()
    arrays.append(build_required_string_column(ids))
    arrays.append(build_string_column(genders))
    arrays.append(build_string_column(birth_dates))
    arrays.append(build_string_column(family_names))
    arrays.append(build_string_column(given_names))
    arrays.append(build_bool_column(deceased))
    return RecordBatch(Int64(len(rows)), arrays)


def patients_to_feather(rows: List[PatientRow], path: String) raises:
    var schema = patient_schema()
    var batch = patients_to_record_batch(rows)
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


def observations_to_record_batch(rows: List[ObservationRow]) raises -> RecordBatch:
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
    for i in range(len(rows)):
        ids.append(rows[i].id)
        patient_refs.append(rows[i].patient_ref)
        codes.append(rows[i].code)
        code_systems.append(rows[i].code_system)
        code_displays.append(rows[i].code_display)
        statuses.append(rows[i].status)
        effective_datetimes.append(rows[i].effective_datetime)
        value_quantities.append(rows[i].value_quantity)
        value_units.append(rows[i].value_unit)
        value_strings.append(rows[i].value_string)

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
    return RecordBatch(Int64(len(rows)), arrays)


def observations_to_feather(rows: List[ObservationRow], path: String) raises:
    var schema = observation_schema()
    var batch = observations_to_record_batch(rows)
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


def conditions_to_record_batch(rows: List[ConditionRow]) raises -> RecordBatch:
    var n = len(rows)
    var ids = List[String](capacity=n)
    var patient_refs = List[Optional[String]](capacity=n)
    var codes = List[Optional[String]](capacity=n)
    var code_displays = List[Optional[String]](capacity=n)
    var clinical_statuses = List[Optional[String]](capacity=n)
    var onset_datetimes = List[Optional[String]](capacity=n)
    var recorded_dates = List[Optional[String]](capacity=n)
    for i in range(len(rows)):
        ids.append(rows[i].id)
        patient_refs.append(rows[i].patient_ref)
        codes.append(rows[i].code)
        code_displays.append(rows[i].code_display)
        clinical_statuses.append(rows[i].clinical_status)
        onset_datetimes.append(rows[i].onset_datetime)
        recorded_dates.append(rows[i].recorded_date)

    var arrays = List[ArrowArray]()
    arrays.append(build_required_string_column(ids))
    arrays.append(build_string_column(patient_refs))
    arrays.append(build_string_column(codes))
    arrays.append(build_string_column(code_displays))
    arrays.append(build_string_column(clinical_statuses))
    arrays.append(build_string_column(onset_datetimes))
    arrays.append(build_string_column(recorded_dates))
    return RecordBatch(Int64(len(rows)), arrays)


def conditions_to_feather(rows: List[ConditionRow], path: String) raises:
    var schema = condition_schema()
    var batch = conditions_to_record_batch(rows)
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
        patients_to_feather(rows, out_path)
    elif kind == "Observation":
        var rows = List[ObservationRow](capacity=len(spans))
        for i in range(len(spans)):
            var span = spans[i]
            rows.append(shred_observation_fast(b[span[0] : span[1]]))
        observations_to_feather(rows, out_path)
    elif kind == "Condition":
        var rows = List[ConditionRow](capacity=len(spans))
        for i in range(len(spans)):
            var span = spans[i]
            rows.append(shred_condition_fast(b[span[0] : span[1]]))
        conditions_to_feather(rows, out_path)
    else:
        raise Error(
            "fhir_arrow: ndjson_to_feather: unknown resource kind '"
            + kind
            + "' (expected Patient, Observation, or Condition)"
        )
