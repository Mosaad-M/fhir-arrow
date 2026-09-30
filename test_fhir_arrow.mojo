from fhir_arrow import (
    ndjson_to_feather, ndjson_range_to_feather, merge_feathers,
    ndjson_to_feather_streaming,
    PatientColumns, shred_patient_fast_into_columns,
    ObservationColumns, shred_observation_fast_into_columns,
    ConditionColumns, shred_condition_fast_into_columns,
    StringColumnBuilder, BoolColumnBuilder, Float64ColumnBuilder,
)
from arrow import (
    ArrowType, ArrowField, ArrowSchema, ArrowArray, RecordBatch,
    encode_arrow_file, decode_arrow_file,
)
from flatbuffers import read_i32_le, read_f64_le
from std.pathlib import Path


def assert_true(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


def assert_eq_str(a: String, b: String, msg: String) raises:
    if a != b:
        raise Error("FAIL: " + msg + ", got '" + a + "', expected '" + b + "'")


def assert_eq_int(a: Int, b: Int, msg: String) raises:
    if a != b:
        raise Error(
            "FAIL: " + msg + ", got " + String(a) + ", expected " + String(b)
        )


def assert_near(a: Float64, b: Float64, msg: String) raises:
    var diff = a - b
    if diff < 0:
        diff = -diff
    if diff > 1e-9:
        raise Error(
            "FAIL: " + msg + ", got " + String(a) + ", expected " + String(b)
        )


# ── Value-reading helpers (test-only: verify what got written) ──────────────


def _is_valid(col: ArrowArray, row: Int) -> Bool:
    if col.null_count == 0:
        return True
    var byte_idx = row // 8
    var bit_idx = row % 8
    return ((col.validity[byte_idx] >> UInt8(bit_idx)) & UInt8(1)) != UInt8(0)


def _get_utf8(col: ArrowArray, row: Int) raises -> String:
    var off_start = Int(read_i32_le(col.offsets, row * 4))
    var off_end = Int(read_i32_le(col.offsets, (row + 1) * 4))
    var sb = List[UInt8]()
    for i in range(off_start, off_end):
        sb.append(col.values[i])
    return String(unsafe_from_utf8=sb^)


def _get_float64(col: ArrowArray, row: Int) raises -> Float64:
    return read_f64_le(col.values, row * 8)


def _get_bool(col: ArrowArray, row: Int) -> Bool:
    var byte_idx = row // 8
    var bit_idx = row % 8
    return ((col.values[byte_idx] >> UInt8(bit_idx)) & UInt8(1)) != UInt8(0)


# ── Streaming column builders: direct roundtrip through a real Feather file ──


def test_string_column_roundtrip_with_null() raises:
    """A 3-row Utf8 column with a null in the middle roundtrips through a
    real Feather file. append_json_string is fed small JSON string
    literals, the same shape it consumes in production."""
    var builder = StringColumnBuilder()
    var s0 = String('"alice"')
    builder.append_json_string(s0.as_bytes(), 0)
    builder.append_null()
    var s2 = String('"carol"')
    builder.append_json_string(s2.as_bytes(), 0)
    var arr = builder^.finish()
    assert_eq_int(arr.null_count, 1, "null_count")

    var fields = List[ArrowField]()
    fields.append(ArrowField("name", ArrowType.utf8(), True))
    var schema = ArrowSchema(fields, Int16(0))

    var arrays = List[ArrowArray]()
    arrays.append(arr.copy())
    var batch = RecordBatch(Int64(3), arrays.copy())
    var batches = List[RecordBatch]()
    batches.append(batch.copy())

    var file_bytes = encode_arrow_file(schema, batches)
    Path("/tmp/fhir_arrow_test_string.feather").write_bytes(file_bytes)

    var result = decode_arrow_file(file_bytes)
    var decoded_batches = result[1].copy()
    var col = decoded_batches[0].columns[0].copy()

    assert_true(_is_valid(col, 0), "row 0 valid")
    assert_eq_str(_get_utf8(col, 0), "alice", "row 0 value")
    assert_true(not _is_valid(col, 1), "row 1 should be null")
    assert_true(_is_valid(col, 2), "row 2 valid")
    assert_eq_str(_get_utf8(col, 2), "carol", "row 2 value")


def test_float64_and_bool_columns_roundtrip_with_nulls() raises:
    """Float64 and Bool columns (each with one null) roundtrip through a real Feather file."""
    var float_builder = Float64ColumnBuilder()
    float_builder.append(5.4)
    float_builder.append_null()

    var bool_builder = BoolColumnBuilder()
    bool_builder.append_null()
    bool_builder.append(True)

    var fields = List[ArrowField]()
    fields.append(ArrowField("val", ArrowType.float_(2), True))
    fields.append(ArrowField("flag", ArrowType.bool_(), True))
    var schema = ArrowSchema(fields, Int16(0))

    var arrays = List[ArrowArray]()
    arrays.append(float_builder^.finish())
    arrays.append(bool_builder^.finish())
    var batch = RecordBatch(Int64(2), arrays.copy())
    var batches = List[RecordBatch]()
    batches.append(batch.copy())

    var file_bytes = encode_arrow_file(schema, batches)
    var result = decode_arrow_file(file_bytes)
    var decoded_batches = result[1].copy()
    var val_col = decoded_batches[0].columns[0].copy()
    var flag_col = decoded_batches[0].columns[1].copy()

    assert_true(_is_valid(val_col, 0), "val row 0 valid")
    assert_near(_get_float64(val_col, 0), 5.4, "val row 0")
    assert_true(not _is_valid(val_col, 1), "val row 1 should be null")

    assert_true(not _is_valid(flag_col, 0), "flag row 0 should be null")
    assert_true(_is_valid(flag_col, 1), "flag row 1 valid")
    assert_true(_get_bool(flag_col, 1), "flag row 1 should be true")


# ── Public API: ndjson_to_feather / ndjson_range_to_feather / merge_feathers ──


def test_ndjson_to_feather_patient_end_to_end() raises:
    """A small Patient NDJSON fixture becomes a Feather file with the right rows/columns."""
    ndjson_to_feather(
        "fixtures/patients_small.ndjson",
        "/tmp/fhir_arrow_patients.feather",
        "Patient",
    )
    var file_bytes = Path("/tmp/fhir_arrow_patients.feather").read_bytes()
    var result = decode_arrow_file(file_bytes)
    var schema = result[0].copy()
    var batches = result[1].copy()
    assert_eq_int(len(schema.fields), 7, "column count")
    assert_eq_int(Int(batches[0].length), 3, "row count")

    var id_col = batches[0].columns[0].copy()
    assert_eq_str(_get_utf8(id_col, 0), "p1", "row 0 id")
    assert_eq_str(_get_utf8(id_col, 1), "p2", "row 1 id")
    assert_eq_str(_get_utf8(id_col, 2), "p3", "row 2 id")

    var family_col = batches[0].columns[3].copy()
    assert_true(_is_valid(family_col, 0), "row 0 family_name valid")
    assert_eq_str(_get_utf8(family_col, 0), "Smith", "row 0 family_name")
    assert_true(not _is_valid(family_col, 1), "row 1 family_name should be null")


def test_ndjson_to_feather_observation_end_to_end() raises:
    """A small Observation NDJSON fixture (mixed valueQuantity/valueString) shreds correctly."""
    ndjson_to_feather(
        "fixtures/observations_small.ndjson",
        "/tmp/fhir_arrow_observations.feather",
        "Observation",
    )
    var file_bytes = Path("/tmp/fhir_arrow_observations.feather").read_bytes()
    var result = decode_arrow_file(file_bytes)
    var batches = result[1].copy()
    assert_eq_int(Int(batches[0].length), 3, "row count")

    var value_quantity_col = batches[0].columns[7].copy()
    var value_string_col = batches[0].columns[9].copy()
    assert_true(_is_valid(value_quantity_col, 0), "row 0 value_quantity valid")
    assert_near(_get_float64(value_quantity_col, 0), 5.4, "row 0 value_quantity")
    assert_true(not _is_valid(value_string_col, 0), "row 0 value_string should be null")
    assert_true(not _is_valid(value_quantity_col, 1), "row 1 value_quantity should be null")
    assert_true(_is_valid(value_string_col, 1), "row 1 value_string valid")
    assert_eq_str(_get_utf8(value_string_col, 1), "no acute findings", "row 1 value_string")


def test_ndjson_to_feather_condition_end_to_end() raises:
    """A small Condition NDJSON fixture (one row missing onsetDateTime) shreds correctly."""
    ndjson_to_feather(
        "fixtures/conditions_small.ndjson",
        "/tmp/fhir_arrow_conditions.feather",
        "Condition",
    )
    var file_bytes = Path("/tmp/fhir_arrow_conditions.feather").read_bytes()
    var result = decode_arrow_file(file_bytes)
    var batches = result[1].copy()
    assert_eq_int(Int(batches[0].length), 2, "row count")

    var onset_col = batches[0].columns[5].copy()
    assert_true(_is_valid(onset_col, 0), "row 0 onset_datetime valid")
    assert_eq_str(_get_utf8(onset_col, 0), "2020-05-01", "row 0 onset_datetime")
    assert_true(not _is_valid(onset_col, 1), "row 1 onset_datetime should be null")


def test_ndjson_range_to_feather_produces_subset() raises:
    """Ndjson_range_to_feather on the byte range covering only rows 0-1 of a
    3-row fixture ([0, 253): row 0 is bytes [0,167), row 1 is [168,252))."""
    ndjson_range_to_feather(
        "fixtures/patients_small.ndjson",
        "/tmp/fhir_arrow_patients_range01.feather",
        "Patient",
        0,
        253,
    )
    var file_bytes = Path("/tmp/fhir_arrow_patients_range01.feather").read_bytes()
    var result = decode_arrow_file(file_bytes)
    var batches = result[1].copy()
    assert_eq_int(Int(batches[0].length), 2, "range row count")
    var id_col = batches[0].columns[0].copy()
    assert_eq_str(_get_utf8(id_col, 0), "p1", "range row 0 id")
    assert_eq_str(_get_utf8(id_col, 1), "p2", "range row 1 id")


def test_merge_feathers_combines_in_order() raises:
    """Two byte-range chunks merge into one file with all rows, chunk order
    preserved (chunk 0: bytes [0,253) = rows p1,p2; chunk 1: bytes [253,
    999999) = row p3, using a past-EOF end since read() short-reads at EOF)."""
    ndjson_range_to_feather(
        "fixtures/patients_small.ndjson",
        "/tmp/fhir_arrow_patients_chunk0.feather",
        "Patient",
        0,
        253,
    )
    ndjson_range_to_feather(
        "fixtures/patients_small.ndjson",
        "/tmp/fhir_arrow_patients_chunk1.feather",
        "Patient",
        253,
        999999,
    )
    var paths = List[String]()
    paths.append("/tmp/fhir_arrow_patients_chunk0.feather")
    paths.append("/tmp/fhir_arrow_patients_chunk1.feather")
    merge_feathers(paths, "/tmp/fhir_arrow_patients_merged.feather")

    var file_bytes = Path("/tmp/fhir_arrow_patients_merged.feather").read_bytes()
    var result = decode_arrow_file(file_bytes)
    var batches = result[1].copy()
    assert_eq_int(len(batches), 2, "merged file should carry 2 RecordBatches")
    assert_eq_int(Int(batches[0].length), 2, "batch 0 row count")
    assert_eq_int(Int(batches[1].length), 1, "batch 1 row count")

    var id_col0 = batches[0].columns[0].copy()
    var id_col1 = batches[1].columns[0].copy()
    assert_eq_str(_get_utf8(id_col0, 0), "p1", "merged batch0 row0 id")
    assert_eq_str(_get_utf8(id_col0, 1), "p2", "merged batch0 row1 id")
    assert_eq_str(_get_utf8(id_col1, 0), "p3", "merged batch1 row0 id")


def test_parallel_chunked_equivalent_to_sequential() raises:
    """The explicit equivalence check the v2 performance-roadmap plan requires:
    chunk+merge (the parallel path's building blocks) must produce identical
    row values, in identical order, to the plain sequential ndjson_to_feather
    on the same input."""
    ndjson_to_feather(
        "fixtures/patients_small.ndjson",
        "/tmp/fhir_arrow_patients_sequential.feather",
        "Patient",
    )
    ndjson_range_to_feather(
        "fixtures/patients_small.ndjson",
        "/tmp/fhir_arrow_patients_eqchunk0.feather",
        "Patient",
        0,
        253,
    )
    ndjson_range_to_feather(
        "fixtures/patients_small.ndjson",
        "/tmp/fhir_arrow_patients_eqchunk1.feather",
        "Patient",
        253,
        999999,
    )
    var paths = List[String]()
    paths.append("/tmp/fhir_arrow_patients_eqchunk0.feather")
    paths.append("/tmp/fhir_arrow_patients_eqchunk1.feather")
    merge_feathers(paths, "/tmp/fhir_arrow_patients_eqmerged.feather")

    var seq_bytes = Path("/tmp/fhir_arrow_patients_sequential.feather").read_bytes()
    var seq_result = decode_arrow_file(seq_bytes)
    var seq_batches = seq_result[1].copy()
    var seq_id_col = seq_batches[0].columns[0].copy()
    var seq_family_col = seq_batches[0].columns[3].copy()
    var seq_deceased_col = seq_batches[0].columns[5].copy()

    var par_bytes = Path("/tmp/fhir_arrow_patients_eqmerged.feather").read_bytes()
    var par_result = decode_arrow_file(par_bytes)
    var par_batches = par_result[1].copy()

    # Flatten the merged (multi-batch) output into one logical row sequence,
    # in batch order, and compare against the sequential single-batch output
    # row by row — this is the actual "same rows, same order" equivalence.
    var par_ids = List[String]()
    var par_families = List[Optional[String]]()
    var par_deceased = List[Optional[Bool]]()
    for bi in range(len(par_batches)):
        var batch = par_batches[bi].copy()
        var id_col = batch.columns[0].copy()
        var family_col = batch.columns[3].copy()
        var deceased_col = batch.columns[5].copy()
        for r in range(Int(batch.length)):
            par_ids.append(_get_utf8(id_col, r))
            if _is_valid(family_col, r):
                par_families.append(Optional[String](_get_utf8(family_col, r)))
            else:
                par_families.append(Optional[String](None))
            if _is_valid(deceased_col, r):
                par_deceased.append(Optional[Bool](_get_bool(deceased_col, r)))
            else:
                par_deceased.append(Optional[Bool](None))

    assert_eq_int(len(par_ids), Int(seq_batches[0].length), "same total row count")
    for r in range(len(par_ids)):
        assert_eq_str(par_ids[r], _get_utf8(seq_id_col, r), "row " + String(r) + " id matches")
        var seq_family_valid = _is_valid(seq_family_col, r)
        assert_true(
            seq_family_valid == Bool(par_families[r]),
            "row " + String(r) + " family_name validity matches",
        )
        if seq_family_valid:
            assert_eq_str(
                par_families[r].value(),
                _get_utf8(seq_family_col, r),
                "row " + String(r) + " family_name value matches",
            )
        var seq_deceased_valid = _is_valid(seq_deceased_col, r)
        assert_true(
            seq_deceased_valid == Bool(par_deceased[r]),
            "row " + String(r) + " deceased validity matches",
        )
        if seq_deceased_valid:
            assert_true(
                par_deceased[r].value() == _get_bool(seq_deceased_col, r),
                "row " + String(r) + " deceased value matches",
            )


# ── Row order, per resource type ──────────────────────────────────────────────
#
# The fused path has no separate row-to-column transpose step (lines are
# appended directly, in scan order, as they're shredded) -- so there's no
# `.pop()`/`.reverse()` dance left to get backwards the way the old
# row-based path's transpose did. Still worth confirming explicitly, not
# assumed from the design reasoning alone.


def test_patient_fused_preserves_row_order() raises:
    var lines = List[String]()
    lines.append(String('{"id": "p1", "gender": "female"}'))
    lines.append(String('{"id": "p2", "gender": "male"}'))
    lines.append(String('{"id": "p3", "gender": "female"}'))

    var columns = PatientColumns()
    for i in range(len(lines)):
        shred_patient_fast_into_columns(lines[i].as_bytes(), columns)
    var batch = columns^.finish()
    assert_eq_int(Int(batch.length), 3, "row count")
    var id_col = batch.columns[0].copy()
    var gender_col = batch.columns[1].copy()
    assert_eq_str(_get_utf8(id_col, 0), "p1", "row 0 id in original order")
    assert_eq_str(_get_utf8(id_col, 1), "p2", "row 1 id in original order")
    assert_eq_str(_get_utf8(id_col, 2), "p3", "row 2 id in original order")
    assert_eq_str(_get_utf8(gender_col, 0), "female", "row 0 gender matches row 0 id")
    assert_eq_str(_get_utf8(gender_col, 1), "male", "row 1 gender matches row 1 id")


def test_observation_fused_preserves_row_order() raises:
    var lines = List[String]()
    lines.append(String('{"id": "o1", "code": {"coding": [{"code": "code-a"}]}}'))
    lines.append(String('{"id": "o2", "code": {"coding": [{"code": "code-b"}]}}'))
    lines.append(String('{"id": "o3", "code": {"coding": [{"code": "code-c"}]}}'))

    var columns = ObservationColumns()
    for i in range(len(lines)):
        shred_observation_fast_into_columns(lines[i].as_bytes(), columns)
    var batch = columns^.finish()
    assert_eq_int(Int(batch.length), 3, "row count")
    var id_col = batch.columns[0].copy()
    var code_col = batch.columns[2].copy()
    assert_eq_str(_get_utf8(id_col, 0), "o1", "row 0 id in original order")
    assert_eq_str(_get_utf8(id_col, 1), "o2", "row 1 id in original order")
    assert_eq_str(_get_utf8(id_col, 2), "o3", "row 2 id in original order")
    assert_eq_str(_get_utf8(code_col, 0), "code-a", "row 0 code matches row 0 id")
    assert_eq_str(_get_utf8(code_col, 2), "code-c", "row 2 code matches row 2 id")


def test_condition_fused_preserves_row_order() raises:
    var lines = List[String]()
    lines.append(String('{"id": "c1", "code": {"coding": [{"code": "code-x"}]}}'))
    lines.append(String('{"id": "c2", "code": {"coding": [{"code": "code-y"}]}}'))
    lines.append(String('{"id": "c3", "code": {"coding": [{"code": "code-z"}]}}'))

    var columns = ConditionColumns()
    for i in range(len(lines)):
        shred_condition_fast_into_columns(lines[i].as_bytes(), columns)
    var batch = columns^.finish()
    assert_eq_int(Int(batch.length), 3, "row count")
    var id_col = batch.columns[0].copy()
    var code_col = batch.columns[2].copy()
    assert_eq_str(_get_utf8(id_col, 0), "c1", "row 0 id in original order")
    assert_eq_str(_get_utf8(id_col, 1), "c2", "row 1 id in original order")
    assert_eq_str(_get_utf8(id_col, 2), "c3", "row 2 id in original order")
    assert_eq_str(_get_utf8(code_col, 0), "code-x", "row 0 code matches row 0 id")
    assert_eq_str(_get_utf8(code_col, 2), "code-z", "row 2 code matches row 2 id")


# ── Fused extraction-into-columns: Patient ────────────────────────────────────
#
# Same fixtures the retired shred_patient_fast's tests used; hardcoded
# expected values now (there's no row-based oracle left to compare
# against once it's deleted).


def test_fused_patient_parity_minimal() raises:
    var line = String(
        '{"resourceType": "Patient", "id": "p1", "gender": "female",'
        ' "birthDate": "1990-01-01"}'
    )
    var columns = PatientColumns()
    shred_patient_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    assert_eq_int(Int(batch.length), 1, "one row")

    var id_col = batch.columns[0].copy()
    var gender_col = batch.columns[1].copy()
    var birth_col = batch.columns[2].copy()
    var family_col = batch.columns[3].copy()
    var given_col = batch.columns[4].copy()
    var deceased_col = batch.columns[5].copy()

    assert_eq_str(_get_utf8(id_col, 0), "p1", "id")
    assert_eq_str(_get_utf8(gender_col, 0), "female", "gender")
    assert_eq_str(_get_utf8(birth_col, 0), "1990-01-01", "birth_date")
    assert_true(not _is_valid(family_col, 0), "family_name should be null")
    assert_true(not _is_valid(given_col, 0), "given_name should be null")
    assert_true(not _is_valid(deceased_col, 0), "deceased should be null")


def test_fused_patient_parity_with_name() raises:
    var line = String(
        '{"id": "p2", "name": [{"family": "Smith", "given": ["Jane", "Q"]}]}'
    )
    var columns = PatientColumns()
    shred_patient_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var family_col = batch.columns[3].copy()
    var given_col = batch.columns[4].copy()

    assert_eq_str(_get_utf8(family_col, 0), "Smith", "family_name")
    assert_eq_str(_get_utf8(given_col, 0), "Jane", "given_name (first only)")


def test_fused_patient_parity_deceased_boolean() raises:
    var line = String('{"id": "p3", "deceasedBoolean": true}')
    var columns = PatientColumns()
    shred_patient_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var deceased_col = batch.columns[5].copy()
    assert_true(_is_valid(deceased_col, 0), "deceased present")
    assert_true(_get_bool(deceased_col, 0) == True, "deceased true")


def test_fused_patient_missing_id_raises() raises:
    var line = String('{"gender": "male"}')
    var columns = PatientColumns()
    var raised = False
    try:
        shred_patient_fast_into_columns(line.as_bytes(), columns)
    except:
        raised = True
    assert_true(raised, "missing id should raise")


def test_fused_patient_parity_escaped_field() raises:
    """Exercises append_json_string's escaped-fallback branch (backslash
    seen before the closing quote), not just the bulk-extend fast path."""
    var line = String(
        '{"id": "p4", "name": [{"family": "O\\"Brien"}]}'
    )
    var columns = PatientColumns()
    shred_patient_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var family_col = batch.columns[3].copy()
    assert_eq_str(_get_utf8(family_col, 0), 'O"Brien', "escaped quote decoded correctly")


def test_fused_patient_raw_json_is_verbatim() raises:
    """Raw_json holds the source line VERBATIM -- an escaped quote inside
    a shredded field must NOT be decoded in raw_json (unlike family_name
    itself), and raw_json must equal the exact source bytes, including
    keys this repo doesn't otherwise shred (e.g. resourceType)."""
    var line = String(
        '{"resourceType": "Patient", "id": "p5",'
        ' "name": [{"family": "O\\"Brien"}], "gender": "female"}'
    )
    var columns = PatientColumns()
    shred_patient_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var raw_col = batch.columns[6].copy()
    assert_eq_str(_get_utf8(raw_col, 0), line, "raw_json is byte-for-byte verbatim")
    assert_true(
        _get_utf8(raw_col, 0).find('O\\"Brien') >= 0,
        "escaped quote left un-decoded in raw_json",
    )
    assert_true(
        _get_utf8(raw_col, 0).find("resourceType") >= 0,
        "raw_json preserves a key this repo doesn't otherwise shred",
    )


def test_fused_patient_multi_row_column_alignment() raises:
    """The one new correctness risk this design introduces: a missing
    append/append_null call for one column would silently shift every
    subsequent row in that column relative to the others. Three rows
    with deliberately different null/present combinations per column --
    if any single append call were dropped, at least one of these
    cross-column checks would fail."""
    var lines = List[String]()
    lines.append(String('{"id": "r1", "gender": "female", "name": [{"family": "Alpha", "given": ["A"]}], "deceasedBoolean": false}'))
    lines.append(String('{"id": "r2", "birthDate": "2000-01-01"}'))
    lines.append(String('{"id": "r3", "gender": "male", "deceasedBoolean": true}'))

    var columns = PatientColumns()
    for i in range(len(lines)):
        shred_patient_fast_into_columns(lines[i].as_bytes(), columns)
    var batch = columns^.finish()
    assert_eq_int(Int(batch.length), 3, "three rows")

    var id_col = batch.columns[0].copy()
    var gender_col = batch.columns[1].copy()
    var birth_col = batch.columns[2].copy()
    var family_col = batch.columns[3].copy()
    var given_col = batch.columns[4].copy()
    var deceased_col = batch.columns[5].copy()
    var raw_col = batch.columns[6].copy()

    assert_eq_str(_get_utf8(id_col, 0), "r1", "row 0 id")
    assert_eq_str(_get_utf8(id_col, 1), "r2", "row 1 id")
    assert_eq_str(_get_utf8(id_col, 2), "r3", "row 2 id")

    assert_true(_is_valid(gender_col, 0), "row 0 gender present")
    assert_eq_str(_get_utf8(gender_col, 0), "female", "row 0 gender value")
    assert_true(not _is_valid(gender_col, 1), "row 1 gender null (misalignment would leak row 0/2's value here)")
    assert_true(_is_valid(gender_col, 2), "row 2 gender present")
    assert_eq_str(_get_utf8(gender_col, 2), "male", "row 2 gender value")

    assert_true(not _is_valid(birth_col, 0), "row 0 birth_date null")
    assert_true(_is_valid(birth_col, 1), "row 1 birth_date present")
    assert_eq_str(_get_utf8(birth_col, 1), "2000-01-01", "row 1 birth_date value")
    assert_true(not _is_valid(birth_col, 2), "row 2 birth_date null")

    assert_true(_is_valid(family_col, 0), "row 0 family_name present")
    assert_eq_str(_get_utf8(family_col, 0), "Alpha", "row 0 family_name value")
    assert_true(not _is_valid(family_col, 1), "row 1 family_name null")
    assert_true(not _is_valid(family_col, 2), "row 2 family_name null")

    assert_true(_is_valid(given_col, 0), "row 0 given_name present")
    assert_eq_str(_get_utf8(given_col, 0), "A", "row 0 given_name value")
    assert_true(not _is_valid(given_col, 1), "row 1 given_name null")
    assert_true(not _is_valid(given_col, 2), "row 2 given_name null")

    assert_true(_is_valid(deceased_col, 0), "row 0 deceased present")
    assert_true(_get_bool(deceased_col, 0) == False, "row 0 deceased false")
    assert_true(not _is_valid(deceased_col, 1), "row 1 deceased null")
    assert_true(_is_valid(deceased_col, 2), "row 2 deceased present")
    assert_true(_get_bool(deceased_col, 2) == True, "row 2 deceased true")

    assert_eq_str(_get_utf8(raw_col, 0), lines[0], "row 0 raw_json matches source line (misalignment would leak here too)")
    assert_eq_str(_get_utf8(raw_col, 1), lines[1], "row 1 raw_json matches source line")
    assert_eq_str(_get_utf8(raw_col, 2), lines[2], "row 2 raw_json matches source line")


# ── Fused extraction-into-columns: Observation ────────────────────────────────
#
# Ports every case from the retired shred_observation_fast's tests
# (including the adversarial ones), hardcoded expected values.


def test_fused_observation_value_quantity() raises:
    var line = String(
        '{"id": "o1", "status": "final",'
        ' "subject": {"reference": "Patient/p1"},'
        ' "code": {"coding": [{"system": "http://loinc.org", "code": "4548-4",'
        ' "display": "Hemoglobin A1c"}]},'
        ' "effectiveDateTime": "2024-01-01T00:00:00Z",'
        ' "valueQuantity": {"value": 5.4, "unit": "%"}}'
    )
    var columns = ObservationColumns()
    shred_observation_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()

    var id_col = batch.columns[0].copy()
    var ref_col = batch.columns[1].copy()
    var code_col = batch.columns[2].copy()
    var system_col = batch.columns[3].copy()
    var display_col = batch.columns[4].copy()
    var status_col = batch.columns[5].copy()
    var eff_col = batch.columns[6].copy()
    var vq_col = batch.columns[7].copy()
    var vu_col = batch.columns[8].copy()
    var vs_col = batch.columns[9].copy()

    assert_eq_str(_get_utf8(id_col, 0), "o1", "id")
    assert_eq_str(_get_utf8(ref_col, 0), "Patient/p1", "patient_ref")
    assert_eq_str(_get_utf8(code_col, 0), "4548-4", "code")
    assert_eq_str(_get_utf8(system_col, 0), "http://loinc.org", "code_system")
    assert_eq_str(_get_utf8(display_col, 0), "Hemoglobin A1c", "code_display")
    assert_eq_str(_get_utf8(status_col, 0), "final", "status")
    assert_eq_str(_get_utf8(eff_col, 0), "2024-01-01T00:00:00Z", "effective_datetime")
    assert_true(_is_valid(vq_col, 0), "value_quantity valid")
    assert_near(_get_float64(vq_col, 0), 5.4, "value_quantity")
    assert_eq_str(_get_utf8(vu_col, 0), "%", "value_unit")
    assert_true(not _is_valid(vs_col, 0), "value_string should be null")


def test_fused_observation_value_string() raises:
    var line = String(
        '{"id": "o2", "code": {"coding": [{"code": "obs-note"}]},'
        ' "valueString": "no acute findings"}'
    )
    var columns = ObservationColumns()
    shred_observation_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var vq_col = batch.columns[7].copy()
    var vu_col = batch.columns[8].copy()
    var vs_col = batch.columns[9].copy()
    assert_eq_str(_get_utf8(vs_col, 0), "no acute findings", "value_string")
    assert_true(not _is_valid(vq_col, 0), "value_quantity should be null")
    assert_true(not _is_valid(vu_col, 0), "value_unit should be null")


def test_fused_observation_no_value() raises:
    var line = String('{"id": "o3", "code": {"coding": [{"code": "x"}]}}')
    var columns = ObservationColumns()
    shred_observation_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var vq_col = batch.columns[7].copy()
    var vs_col = batch.columns[9].copy()
    assert_true(not _is_valid(vq_col, 0), "value_quantity should be null")
    assert_true(not _is_valid(vs_col, 0), "value_string should be null")


def test_fused_observation_missing_id_raises() raises:
    var line = String('{"status": "final"}')
    var columns = ObservationColumns()
    var raised = False
    try:
        shred_observation_fast_into_columns(line.as_bytes(), columns)
    except:
        raised = True
    assert_true(raised, "missing id should raise")


def test_fused_observation_note_with_escaped_structural_chars() raises:
    """A 'note' field (not in our schema, so it's skipped) containing
    escaped quotes/braces/brackets must not corrupt extraction of the
    real fields that come after it."""
    var line = String(
        '{"id": "o4", "note": "patient said \\"ok\\", {no code} [fine]",'
        ' "status": "final", "code": {"coding": [{"code": "9279-1"}]}}'
    )
    var columns = ObservationColumns()
    shred_observation_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var id_col = batch.columns[0].copy()
    var status_col = batch.columns[5].copy()
    var code_col = batch.columns[2].copy()
    assert_eq_str(_get_utf8(id_col, 0), "o4", "id")
    assert_eq_str(_get_utf8(status_col, 0), "final", "status survives the adversarial note field")
    assert_eq_str(_get_utf8(code_col, 0), "9279-1", "code survives the adversarial note field")


def test_fused_observation_code_key_collision() raises:
    """'code' exists as a top-level CodeableConcept object AND as a key
    inside coding[0]. Must extract the nested coding[0].code ('4548-4'),
    not be confused by the top-level 'code' object itself."""
    var line = String(
        '{"id": "o5", "code": {"coding": [{"system": "http://loinc.org",'
        ' "code": "4548-4", "display": "Hemoglobin A1c"}]}}'
    )
    var columns = ObservationColumns()
    shred_observation_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var code_col = batch.columns[2].copy()
    assert_eq_str(_get_utf8(code_col, 0), "4548-4", "should read coding[0].code, not confuse the outer object")


def test_fused_observation_out_of_order_with_unknown_fields() raises:
    """Real Synthea output won't match hand-written fixture key ordering,
    and carries many fields (meta, text, category, encounter, performer)
    this v0 doesn't care about, interspersed among the fields it does."""
    var line = String(
        '{"resourceType": "Observation",'
        ' "meta": {"versionId": "1", "lastUpdated": "2024-01-01T00:00:00Z"},'
        ' "status": "final",'
        ' "category": [{"coding": [{"system": "http://x", "code": "vital-signs"}]}],'
        ' "code": {"coding": [{"system": "http://loinc.org", "code": "8302-2",'
        ' "display": "Body Height"}]},'
        ' "subject": {"reference": "Patient/p1"},'
        ' "encounter": {"reference": "Encounter/e1"},'
        ' "effectiveDateTime": "2024-01-01T00:00:00Z",'
        ' "valueQuantity": {"value": 170.0, "unit": "cm", "system": "http://unitsofmeasure.org"},'
        ' "id": "o6"}'
    )
    var columns = ObservationColumns()
    shred_observation_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var id_col = batch.columns[0].copy()
    var code_col = batch.columns[2].copy()
    var ref_col = batch.columns[1].copy()
    var vq_col = batch.columns[7].copy()
    var vu_col = batch.columns[8].copy()
    assert_eq_str(_get_utf8(id_col, 0), "o6", "id found despite appearing last")
    assert_eq_str(_get_utf8(code_col, 0), "8302-2", "code found past the unrelated category coding array")
    assert_eq_str(_get_utf8(ref_col, 0), "Patient/p1", "patient_ref")
    assert_near(_get_float64(vq_col, 0), 170.0, "value_quantity")
    assert_eq_str(_get_utf8(vu_col, 0), "cm", "value_unit (not confused by valueQuantity.system)")


def test_fused_observation_multiple_coding_entries() raises:
    """Only coding[0] should be read when multiple entries are present."""
    var line = String(
        '{"id": "o7", "code": {"coding": ['
        '{"system": "http://loinc.org", "code": "FIRST", "display": "First Code"},'
        '{"system": "http://snomed.info/sct", "code": "SECOND", "display": "Second Code"}'
        ']}}'
    )
    var columns = ObservationColumns()
    shred_observation_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var code_col = batch.columns[2].copy()
    var display_col = batch.columns[4].copy()
    assert_eq_str(_get_utf8(code_col, 0), "FIRST", "only the first coding entry should be read")
    assert_eq_str(_get_utf8(display_col, 0), "First Code", "only the first coding entry should be read")


def test_fused_observation_raw_json_is_verbatim() raises:
    """Raw_json holds the source line VERBATIM, including keys this repo
    doesn't otherwise shred (e.g. meta, category)."""
    var line = String(
        '{"resourceType": "Observation", "meta": {"versionId": "1"},'
        ' "id": "o8", "status": "final"}'
    )
    var columns = ObservationColumns()
    shred_observation_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var raw_col = batch.columns[10].copy()
    assert_eq_str(_get_utf8(raw_col, 0), line, "raw_json is byte-for-byte verbatim")
    assert_true(
        _get_utf8(raw_col, 0).find("meta") >= 0,
        "raw_json preserves a key this repo doesn't otherwise shred",
    )


def test_fused_observation_multi_row_column_alignment() raises:
    """Same alignment risk as Patient's version, but for Observation's 10
    columns -- more sibling-column surface, and specifically exercises the
    polymorphic valueQuantity/valueString branch across rows."""
    var lines = List[String]()
    lines.append(String('{"id": "r1", "status": "final", "code": {"coding": [{"code": "c1"}]}, "valueQuantity": {"value": 1.5, "unit": "kg"}}'))
    lines.append(String('{"id": "r2", "subject": {"reference": "Patient/p9"}, "valueString": "note text"}'))
    lines.append(String('{"id": "r3", "effectiveDateTime": "2021-01-01"}'))

    var columns = ObservationColumns()
    for i in range(len(lines)):
        shred_observation_fast_into_columns(lines[i].as_bytes(), columns)
    var batch = columns^.finish()
    assert_eq_int(Int(batch.length), 3, "three rows")

    var id_col = batch.columns[0].copy()
    var ref_col = batch.columns[1].copy()
    var code_col = batch.columns[2].copy()
    var status_col = batch.columns[5].copy()
    var eff_col = batch.columns[6].copy()
    var vq_col = batch.columns[7].copy()
    var vu_col = batch.columns[8].copy()
    var vs_col = batch.columns[9].copy()
    var raw_col = batch.columns[10].copy()

    assert_eq_str(_get_utf8(id_col, 0), "r1", "row 0 id")
    assert_eq_str(_get_utf8(id_col, 1), "r2", "row 1 id")
    assert_eq_str(_get_utf8(id_col, 2), "r3", "row 2 id")

    assert_true(_is_valid(status_col, 0), "row 0 status present")
    assert_true(not _is_valid(status_col, 1), "row 1 status null (misalignment would leak here)")
    assert_true(not _is_valid(status_col, 2), "row 2 status null")

    assert_true(not _is_valid(ref_col, 0), "row 0 patient_ref null")
    assert_true(_is_valid(ref_col, 1), "row 1 patient_ref present")
    assert_eq_str(_get_utf8(ref_col, 1), "Patient/p9", "row 1 patient_ref value")
    assert_true(not _is_valid(ref_col, 2), "row 2 patient_ref null")

    assert_true(_is_valid(code_col, 0), "row 0 code present")
    assert_eq_str(_get_utf8(code_col, 0), "c1", "row 0 code value")
    assert_true(not _is_valid(code_col, 1), "row 1 code null")
    assert_true(not _is_valid(code_col, 2), "row 2 code null")

    assert_true(_is_valid(vq_col, 0), "row 0 value_quantity present")
    assert_near(_get_float64(vq_col, 0), 1.5, "row 0 value_quantity")
    assert_true(_is_valid(vu_col, 0), "row 0 value_unit present")
    assert_eq_str(_get_utf8(vu_col, 0), "kg", "row 0 value_unit")
    assert_true(not _is_valid(vs_col, 0), "row 0 value_string null (only one value[x] variant per row)")

    assert_true(not _is_valid(vq_col, 1), "row 1 value_quantity null")
    assert_true(not _is_valid(vu_col, 1), "row 1 value_unit null")
    assert_true(_is_valid(vs_col, 1), "row 1 value_string present")
    assert_eq_str(_get_utf8(vs_col, 1), "note text", "row 1 value_string")

    assert_true(not _is_valid(vq_col, 2), "row 2 value_quantity null")
    assert_true(not _is_valid(vs_col, 2), "row 2 value_string null")
    assert_true(_is_valid(eff_col, 2), "row 2 effective_datetime present")
    assert_eq_str(_get_utf8(eff_col, 2), "2021-01-01", "row 2 effective_datetime")
    assert_true(not _is_valid(eff_col, 0), "row 0 effective_datetime null")
    assert_true(not _is_valid(eff_col, 1), "row 1 effective_datetime null")

    assert_eq_str(_get_utf8(raw_col, 0), lines[0], "row 0 raw_json matches source line (misalignment would leak here too)")
    assert_eq_str(_get_utf8(raw_col, 1), lines[1], "row 1 raw_json matches source line")
    assert_eq_str(_get_utf8(raw_col, 2), lines[2], "row 2 raw_json matches source line")


# ── Fused extraction-into-columns: Condition ──────────────────────────────────
#
# Ports every case from the retired shred_condition_fast's tests,
# hardcoded expected values.


def test_fused_condition_full() raises:
    var line = String(
        '{"id": "c1", "subject": {"reference": "Patient/p1"},'
        ' "code": {"coding": [{"code": "44054006", "display": "Diabetes"}]},'
        ' "clinicalStatus": {"coding": [{"code": "active"}]},'
        ' "onsetDateTime": "2020-05-01",'
        ' "recordedDate": "2020-05-02"}'
    )
    var columns = ConditionColumns()
    shred_condition_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()

    var id_col = batch.columns[0].copy()
    var ref_col = batch.columns[1].copy()
    var code_col = batch.columns[2].copy()
    var display_col = batch.columns[3].copy()
    var status_col = batch.columns[4].copy()
    var onset_col = batch.columns[5].copy()
    var recorded_col = batch.columns[6].copy()

    assert_eq_str(_get_utf8(id_col, 0), "c1", "id")
    assert_eq_str(_get_utf8(ref_col, 0), "Patient/p1", "patient_ref")
    assert_eq_str(_get_utf8(code_col, 0), "44054006", "code")
    assert_eq_str(_get_utf8(display_col, 0), "Diabetes", "code_display")
    assert_eq_str(_get_utf8(status_col, 0), "active", "clinical_status")
    assert_eq_str(_get_utf8(onset_col, 0), "2020-05-01", "onset_datetime")
    assert_eq_str(_get_utf8(recorded_col, 0), "2020-05-02", "recorded_date")


def test_fused_condition_raw_json_is_verbatim() raises:
    """Raw_json holds the source line VERBATIM, including keys this repo
    doesn't otherwise shred (e.g. encounter)."""
    var line = String(
        '{"id": "c4", "encounter": {"reference": "Encounter/e1"},'
        ' "code": {"coding": [{"code": "44054006"}]}}'
    )
    var columns = ConditionColumns()
    shred_condition_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var raw_col = batch.columns[7].copy()
    assert_eq_str(_get_utf8(raw_col, 0), line, "raw_json is byte-for-byte verbatim")
    assert_true(
        _get_utf8(raw_col, 0).find("encounter") >= 0,
        "raw_json preserves a key this repo doesn't otherwise shred",
    )


def test_fused_condition_no_onset() raises:
    var line = String('{"id": "c2", "code": {"coding": [{"code": "x"}]}}')
    var columns = ConditionColumns()
    shred_condition_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var onset_col = batch.columns[5].copy()
    assert_true(not _is_valid(onset_col, 0), "onset_datetime should be null")


def test_fused_condition_missing_id_raises() raises:
    var line = String('{"code": {"coding": [{"code": "x"}]}}')
    var columns = ConditionColumns()
    var raised = False
    try:
        shred_condition_fast_into_columns(line.as_bytes(), columns)
    except:
        raised = True
    assert_true(raised, "missing id should raise")


def test_fused_condition_unicode_escape_in_skipped_field() raises:
    """A unicode escape inside a skipped field (not in our schema) must
    not desynchronize byte offsets for the fields that follow it."""
    var line = String(
        '{"id": "c3", "note": "caf\\u00e9 follow-up",'
        ' "code": {"coding": [{"code": "44054006", "display": "Diabetes"}]},'
        ' "onsetDateTime": "2020-05-01"}'
    )
    var columns = ConditionColumns()
    shred_condition_fast_into_columns(line.as_bytes(), columns)
    var batch = columns^.finish()
    var id_col = batch.columns[0].copy()
    var code_col = batch.columns[2].copy()
    var onset_col = batch.columns[5].copy()
    assert_eq_str(_get_utf8(id_col, 0), "c3", "id")
    assert_eq_str(_get_utf8(code_col, 0), "44054006", "code survives the unicode escape in note")
    assert_eq_str(_get_utf8(onset_col, 0), "2020-05-01", "onset_datetime survives the unicode escape in note")


def test_fused_condition_multi_row_column_alignment() raises:
    """Same alignment risk as Patient/Observation's versions, for
    Condition's 7 columns."""
    var lines = List[String]()
    lines.append(String('{"id": "r1", "subject": {"reference": "Patient/p1"}, "clinicalStatus": {"coding": [{"code": "active"}]}}'))
    lines.append(String('{"id": "r2", "code": {"coding": [{"code": "c2", "display": "D2"}]}, "recordedDate": "2022-02-02"}'))
    lines.append(String('{"id": "r3", "onsetDateTime": "2023-03-03"}'))

    var columns = ConditionColumns()
    for i in range(len(lines)):
        shred_condition_fast_into_columns(lines[i].as_bytes(), columns)
    var batch = columns^.finish()
    assert_eq_int(Int(batch.length), 3, "three rows")

    var id_col = batch.columns[0].copy()
    var ref_col = batch.columns[1].copy()
    var code_col = batch.columns[2].copy()
    var display_col = batch.columns[3].copy()
    var status_col = batch.columns[4].copy()
    var onset_col = batch.columns[5].copy()
    var recorded_col = batch.columns[6].copy()
    var raw_col = batch.columns[7].copy()

    assert_eq_str(_get_utf8(id_col, 0), "r1", "row 0 id")
    assert_eq_str(_get_utf8(id_col, 1), "r2", "row 1 id")
    assert_eq_str(_get_utf8(id_col, 2), "r3", "row 2 id")

    assert_true(_is_valid(ref_col, 0), "row 0 patient_ref present")
    assert_eq_str(_get_utf8(ref_col, 0), "Patient/p1", "row 0 patient_ref value")
    assert_true(not _is_valid(ref_col, 1), "row 1 patient_ref null (misalignment would leak here)")
    assert_true(not _is_valid(ref_col, 2), "row 2 patient_ref null")

    assert_true(_is_valid(status_col, 0), "row 0 clinical_status present")
    assert_eq_str(_get_utf8(status_col, 0), "active", "row 0 clinical_status value")
    assert_true(not _is_valid(status_col, 1), "row 1 clinical_status null")
    assert_true(not _is_valid(status_col, 2), "row 2 clinical_status null")

    assert_true(not _is_valid(code_col, 0), "row 0 code null")
    assert_true(_is_valid(code_col, 1), "row 1 code present")
    assert_eq_str(_get_utf8(code_col, 1), "c2", "row 1 code value")
    assert_true(_is_valid(display_col, 1), "row 1 code_display present")
    assert_eq_str(_get_utf8(display_col, 1), "D2", "row 1 code_display value")
    assert_true(not _is_valid(code_col, 2), "row 2 code null")

    assert_true(_is_valid(recorded_col, 1), "row 1 recorded_date present")
    assert_eq_str(_get_utf8(recorded_col, 1), "2022-02-02", "row 1 recorded_date value")
    assert_true(not _is_valid(recorded_col, 0), "row 0 recorded_date null")
    assert_true(not _is_valid(recorded_col, 2), "row 2 recorded_date null")

    assert_true(_is_valid(onset_col, 2), "row 2 onset_datetime present")
    assert_eq_str(_get_utf8(onset_col, 2), "2023-03-03", "row 2 onset_datetime value")
    assert_true(not _is_valid(onset_col, 0), "row 0 onset_datetime null")
    assert_true(not _is_valid(onset_col, 1), "row 1 onset_datetime null")

    assert_eq_str(_get_utf8(raw_col, 0), lines[0], "row 0 raw_json matches source line (misalignment would leak here too)")
    assert_eq_str(_get_utf8(raw_col, 1), lines[1], "row 1 raw_json matches source line")
    assert_eq_str(_get_utf8(raw_col, 2), lines[2], "row 2 raw_json matches source line")


# ── ndjson_to_feather_streaming: bounded-memory sequential path ─────────────


def _with_blank_lines(fixture: String, out_path: String) raises:
    """Copies a fixture with blank lines between records, so small chunks
    can land on nothing but blank lines -- which streaming must skip."""
    var content = Path(fixture).read_text()
    var out = String("\n")
    var start = 0
    while True:
        var idx = content.find("\n", start)
        if idx < 0:
            out += String(content[byte=start:])
            break
        out += String(content[byte=start : idx + 1]) + "\n\n"
        start = idx + 1
    Path(out_path).write_text(out)


def _flattened_ids(path: String) raises -> List[String]:
    var result = decode_arrow_file(Path(path).read_bytes())
    var ids = List[String]()
    for batch in result[1]:
        var id_col = batch.columns[0].copy()
        for r in range(Int(batch.length)):
            ids.append(_get_utf8(id_col, r))
    return ids^


def _assert_streaming_matches_sequential(fixture: String, kind: String) raises:
    var src = "/tmp/fhir_arrow_stream_src_" + kind + ".ndjson"
    _with_blank_lines(fixture, src)
    ndjson_to_feather(src, "/tmp/fhir_arrow_stream_seq.feather", kind)
    var expected = _flattened_ids("/tmp/fhir_arrow_stream_seq.feather")
    assert_true(len(expected) >= 2, kind + ": fixture has multiple records")
    var sizes = List[Int]()
    sizes.append(1)
    sizes.append(100)
    sizes.append(1000000)
    for size in sizes:
        ndjson_to_feather_streaming(src, "/tmp/fhir_arrow_stream_out.feather", kind, size)
        var actual = _flattened_ids("/tmp/fhir_arrow_stream_out.feather")
        var label = kind + " chunk=" + String(size)
        assert_eq_int(len(actual), len(expected), label + ": row count")
        for r in range(len(expected)):
            assert_eq_str(actual[r], expected[r], label + " row " + String(r) + " id")


def test_streaming_equivalent_to_sequential_all_kinds() raises:
    """Streaming output must match ndjson_to_feather row for row, in order,
    for every resource kind, at chunk sizes from one byte (every record its
    own chunk, many chunks blank) up to larger than the file."""
    _assert_streaming_matches_sequential("fixtures/patients_small.ndjson", "Patient")
    _assert_streaming_matches_sequential("fixtures/observations_small.ndjson", "Observation")
    _assert_streaming_matches_sequential("fixtures/conditions_small.ndjson", "Condition")


def test_streaming_small_chunks_produce_multiple_batches() raises:
    """Guards against a streaming path that silently reads the file as one
    chunk: one-byte chunks must yield one RecordBatch per record."""
    var src = "/tmp/fhir_arrow_stream_src_Patient.ndjson"
    _with_blank_lines("fixtures/patients_small.ndjson", src)
    ndjson_to_feather_streaming(src, "/tmp/fhir_arrow_stream_out.feather", "Patient", 1)
    var result = decode_arrow_file(Path("/tmp/fhir_arrow_stream_out.feather").read_bytes())
    assert_eq_int(len(result[1]), 3, "one batch per patient record")


def test_streaming_rejects_bad_arguments() raises:
    var raised = False
    try:
        ndjson_to_feather_streaming(
            "fixtures/patients_small.ndjson", "/tmp/fhir_arrow_stream_bad.feather", "Patient", 0
        )
    except:
        raised = True
    assert_true(raised, "max_chunk_bytes=0 should raise")
    raised = False
    try:
        ndjson_to_feather_streaming(
            "fixtures/patients_small.ndjson", "/tmp/fhir_arrow_stream_bad.feather", "Encounter"
        )
    except:
        raised = True
    assert_true(raised, "unknown kind should raise")


def test_streaming_no_records_raises() raises:
    """Same contract as ndjson_to_feather: no records at all is an error."""
    Path("/tmp/fhir_arrow_stream_blank.ndjson").write_text("\n\n\n")
    var raised = False
    try:
        ndjson_to_feather_streaming(
            "/tmp/fhir_arrow_stream_blank.ndjson", "/tmp/fhir_arrow_stream_bad.feather", "Patient", 2
        )
    except:
        raised = True
    assert_true(raised, "all-blank file should raise")


def main() raises:
    test_string_column_roundtrip_with_null()
    print("PASS test_string_column_roundtrip_with_null")

    test_float64_and_bool_columns_roundtrip_with_nulls()
    print("PASS test_float64_and_bool_columns_roundtrip_with_nulls")

    test_ndjson_to_feather_patient_end_to_end()
    print("PASS test_ndjson_to_feather_patient_end_to_end")

    test_ndjson_to_feather_observation_end_to_end()
    print("PASS test_ndjson_to_feather_observation_end_to_end")

    test_ndjson_to_feather_condition_end_to_end()
    print("PASS test_ndjson_to_feather_condition_end_to_end")

    test_ndjson_range_to_feather_produces_subset()
    print("PASS test_ndjson_range_to_feather_produces_subset")

    test_merge_feathers_combines_in_order()
    print("PASS test_merge_feathers_combines_in_order")

    test_parallel_chunked_equivalent_to_sequential()
    print("PASS test_parallel_chunked_equivalent_to_sequential")

    test_patient_fused_preserves_row_order()
    print("PASS test_patient_fused_preserves_row_order")

    test_observation_fused_preserves_row_order()
    print("PASS test_observation_fused_preserves_row_order")

    test_condition_fused_preserves_row_order()
    print("PASS test_condition_fused_preserves_row_order")

    test_fused_patient_parity_minimal()
    print("PASS test_fused_patient_parity_minimal")

    test_fused_patient_parity_with_name()
    print("PASS test_fused_patient_parity_with_name")

    test_fused_patient_parity_deceased_boolean()
    print("PASS test_fused_patient_parity_deceased_boolean")

    test_fused_patient_missing_id_raises()
    print("PASS test_fused_patient_missing_id_raises")

    test_fused_patient_parity_escaped_field()
    print("PASS test_fused_patient_parity_escaped_field")

    test_fused_patient_raw_json_is_verbatim()
    print("PASS test_fused_patient_raw_json_is_verbatim")

    test_fused_patient_multi_row_column_alignment()
    print("PASS test_fused_patient_multi_row_column_alignment")

    test_fused_observation_value_quantity()
    print("PASS test_fused_observation_value_quantity")

    test_fused_observation_value_string()
    print("PASS test_fused_observation_value_string")

    test_fused_observation_no_value()
    print("PASS test_fused_observation_no_value")

    test_fused_observation_missing_id_raises()
    print("PASS test_fused_observation_missing_id_raises")

    test_fused_observation_note_with_escaped_structural_chars()
    print("PASS test_fused_observation_note_with_escaped_structural_chars")

    test_fused_observation_code_key_collision()
    print("PASS test_fused_observation_code_key_collision")

    test_fused_observation_out_of_order_with_unknown_fields()
    print("PASS test_fused_observation_out_of_order_with_unknown_fields")

    test_fused_observation_multiple_coding_entries()
    print("PASS test_fused_observation_multiple_coding_entries")

    test_fused_observation_raw_json_is_verbatim()
    print("PASS test_fused_observation_raw_json_is_verbatim")

    test_fused_observation_multi_row_column_alignment()
    print("PASS test_fused_observation_multi_row_column_alignment")

    test_fused_condition_full()
    print("PASS test_fused_condition_full")

    test_fused_condition_raw_json_is_verbatim()
    print("PASS test_fused_condition_raw_json_is_verbatim")

    test_fused_condition_no_onset()
    print("PASS test_fused_condition_no_onset")

    test_fused_condition_missing_id_raises()
    print("PASS test_fused_condition_missing_id_raises")

    test_fused_condition_unicode_escape_in_skipped_field()
    print("PASS test_fused_condition_unicode_escape_in_skipped_field")

    test_fused_condition_multi_row_column_alignment()
    print("PASS test_fused_condition_multi_row_column_alignment")

    test_streaming_equivalent_to_sequential_all_kinds()
    print("PASS test_streaming_equivalent_to_sequential_all_kinds")
    test_streaming_small_chunks_produce_multiple_batches()
    print("PASS test_streaming_small_chunks_produce_multiple_batches")
    test_streaming_rejects_bad_arguments()
    print("PASS test_streaming_rejects_bad_arguments")
    test_streaming_no_records_raises()
    print("PASS test_streaming_no_records_raises")

    print("\nAll fhir_arrow builder tests passed.")
