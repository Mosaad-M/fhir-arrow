from fhir_arrow import (
    build_string_column, build_required_string_column,
    build_float64_column, build_bool_column,
    ndjson_to_feather, ndjson_range_to_feather, merge_feathers,
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


# ── Tests ─────────────────────────────────────────────────────────────────────


def test_string_column_roundtrip_with_null() raises:
    """A 3-row Utf8 column with a null in the middle roundtrips through a real Feather file."""
    var values = List[Optional[String]]()
    values.append(Optional[String]("alice"))
    values.append(Optional[String](None))
    values.append(Optional[String]("carol"))

    var arr = build_string_column(values)
    assert_eq_int(arr.null_count, 1, "null_count")

    var fields = List[ArrowField]()
    fields.append(ArrowField("name", ArrowType.utf8(), True))
    var schema = ArrowSchema(fields, Int16(0))

    var arrays = List[ArrowArray]()
    arrays.append(arr.copy())
    var batch = RecordBatch(Int64(3), arrays)
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
    var floats = List[Optional[Float64]]()
    floats.append(Optional[Float64](5.4))
    floats.append(Optional[Float64](None))

    var bools = List[Optional[Bool]]()
    bools.append(Optional[Bool](None))
    bools.append(Optional[Bool](True))

    var fields = List[ArrowField]()
    fields.append(ArrowField("val", ArrowType.float_(2), True))
    fields.append(ArrowField("flag", ArrowType.bool_(), True))
    var schema = ArrowSchema(fields, Int16(0))

    var arrays = List[ArrowArray]()
    arrays.append(build_float64_column(floats))
    arrays.append(build_bool_column(bools))
    var batch = RecordBatch(Int64(2), arrays)
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
    assert_eq_int(len(schema.fields), 6, "column count")
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

    print("\nAll fhir_arrow builder tests passed.")
