from ndjson import read_ndjson_lines
from std.pathlib import Path


def assert_true(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


def assert_eq_int(a: Int, b: Int, msg: String) raises:
    if a != b:
        raise Error(
            "FAIL: " + msg + ", got " + String(a) + ", expected " + String(b)
        )


def _write(path: String, content: String) raises:
    Path(path).write_text(content)


def test_read_ndjson_lines_rejects_empty_file() raises:
    """An empty NDJSON file is a usage error, not zero rows."""
    _write("/tmp/fhir_arrow_test_lines_empty.ndjson", "")
    var raised = False
    try:
        _ = read_ndjson_lines("/tmp/fhir_arrow_test_lines_empty.ndjson")
    except:
        raised = True
    assert_true(raised, "empty file should raise")


def test_read_ndjson_lines_skips_blank_lines() raises:
    """Blank lines between/around records are skipped, not returned."""
    _write(
        "/tmp/fhir_arrow_test_lines_blank.ndjson",
        '{"a": 1}\n\n{"a": 2}\n\n',
    )
    var lines = read_ndjson_lines("/tmp/fhir_arrow_test_lines_blank.ndjson")
    assert_eq_int(len(lines), 2, "line count")
    assert_true(lines[0] == '{"a": 1}', "line 0 raw text")
    assert_true(lines[1] == '{"a": 2}', "line 1 raw text")


def test_read_ndjson_lines_returns_n_raw_strings_in_order() raises:
    """A well-formed N-line NDJSON file yields N raw strings, in order,
    with no JSON parsing performed."""
    _write(
        "/tmp/fhir_arrow_test_lines_n.ndjson",
        '{"a": 1}\n{"a": 2}\n{"a": 3}\n',
    )
    var lines = read_ndjson_lines("/tmp/fhir_arrow_test_lines_n.ndjson")
    assert_eq_int(len(lines), 3, "line count")
    assert_true(lines[0] == '{"a": 1}', "line 0")
    assert_true(lines[1] == '{"a": 2}', "line 1")
    assert_true(lines[2] == '{"a": 3}', "line 2")


def test_read_ndjson_lines_does_not_reject_invalid_json() raises:
    """read_ndjson_lines never parses: a line that wouldn't be valid JSON
    is still returned as-is. (Validity is checked later, per field, inside
    fast_shred.mojo's shred_*_fast functions.)"""
    _write(
        "/tmp/fhir_arrow_test_lines_notjson.ndjson",
        '{"a": 1}\nnot json at all\n{"a": 3}\n',
    )
    var lines = read_ndjson_lines("/tmp/fhir_arrow_test_lines_notjson.ndjson")
    assert_eq_int(len(lines), 3, "line count")
    assert_true(lines[1] == "not json at all", "line 1 passed through raw")


def main() raises:
    test_read_ndjson_lines_rejects_empty_file()
    print("PASS test_read_ndjson_lines_rejects_empty_file")

    test_read_ndjson_lines_skips_blank_lines()
    print("PASS test_read_ndjson_lines_skips_blank_lines")

    test_read_ndjson_lines_returns_n_raw_strings_in_order()
    print("PASS test_read_ndjson_lines_returns_n_raw_strings_in_order")

    test_read_ndjson_lines_does_not_reject_invalid_json()
    print("PASS test_read_ndjson_lines_does_not_reject_invalid_json")

    print("\nAll ndjson tests passed.")
