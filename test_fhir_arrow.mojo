from fhir_arrow import (
    build_string_column, build_required_string_column,
    build_float64_column, build_bool_column,
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


def main() raises:
    test_string_column_roundtrip_with_null()
    print("PASS test_string_column_roundtrip_with_null")

    test_float64_and_bool_columns_roundtrip_with_nulls()
    print("PASS test_float64_and_bool_columns_roundtrip_with_nulls")

    print("\nAll fhir_arrow builder tests passed.")
