from ndjson import read_ndjson
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


def test_read_ndjson_rejects_empty_file() raises:
    """An empty NDJSON file is a usage error, not zero rows."""
    _write("/tmp/fhir_arrow_test_empty.ndjson", "")
    var raised = False
    try:
        _ = read_ndjson("/tmp/fhir_arrow_test_empty.ndjson")
    except:
        raised = True
    assert_true(raised, "empty file should raise")


def test_read_ndjson_skips_blank_lines() raises:
    """Blank lines between/around records are skipped, not parsed."""
    _write(
        "/tmp/fhir_arrow_test_blank.ndjson",
        '{"a": 1}\n\n{"a": 2}\n\n',
    )
    var rows = read_ndjson("/tmp/fhir_arrow_test_blank.ndjson")
    assert_eq_int(len(rows), 2, "row count")
    assert_eq_int(rows[0].get_int("a"), 1, "row 0 a")
    assert_eq_int(rows[1].get_int("a"), 2, "row 1 a")


def test_read_ndjson_parses_n_lines() raises:
    """A well-formed N-line NDJSON file yields N JsonValues, in order."""
    _write(
        "/tmp/fhir_arrow_test_n.ndjson",
        '{"a": 1}\n{"a": 2}\n{"a": 3}\n',
    )
    var rows = read_ndjson("/tmp/fhir_arrow_test_n.ndjson")
    assert_eq_int(len(rows), 3, "row count")
    assert_eq_int(rows[0].get_int("a"), 1, "row 0")
    assert_eq_int(rows[1].get_int("a"), 2, "row 1")
    assert_eq_int(rows[2].get_int("a"), 3, "row 2")


def test_read_ndjson_malformed_line_raises_with_line_number() raises:
    """A malformed line's error message names the 1-based line number."""
    _write(
        "/tmp/fhir_arrow_test_bad.ndjson",
        '{"a": 1}\n{not json}\n{"a": 3}\n',
    )
    var raised = False
    var msg = String("")
    try:
        _ = read_ndjson("/tmp/fhir_arrow_test_bad.ndjson")
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "malformed line should raise")
    assert_true("line 2" in msg, "error should mention line 2, got: " + msg)


def main() raises:
    test_read_ndjson_rejects_empty_file()
    print("PASS test_read_ndjson_rejects_empty_file")

    test_read_ndjson_skips_blank_lines()
    print("PASS test_read_ndjson_skips_blank_lines")

    test_read_ndjson_parses_n_lines()
    print("PASS test_read_ndjson_parses_n_lines")

    test_read_ndjson_malformed_line_raises_with_line_number()
    print("PASS test_read_ndjson_malformed_line_raises_with_line_number")

    print("\nAll ndjson tests passed.")
