from ndjson import find_line_spans, read_ndjson_lines
from std.pathlib import Path


def assert_true(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


def assert_eq_int(a: Int, b: Int, msg: String) raises:
    if a != b:
        raise Error(
            "FAIL: " + msg + ", got " + String(a) + ", expected " + String(b)
        )


def assert_eq_str(a: String, b: String, msg: String) raises:
    if a != b:
        raise Error("FAIL: " + msg + ", got '" + a + "', expected '" + b + "'")


def _write(path: String, content: String) raises:
    Path(path).write_text(content)


def _slice(content: String, span: Tuple[Int, Int]) raises -> String:
    var b = content.as_bytes()
    return String(unsafe_from_utf8=b[span[0] : span[1]])


# ── find_line_spans: the new byte-boundary primitive, tested directly ───────


def test_find_line_spans_offsets_correct() raises:
    """(start, end) pairs must point at exactly the right bytes in the
    original buffer, not just be the right count."""
    var content = String('{"a": 1}\n{"a": 22}\n')
    var spans = find_line_spans(content.as_bytes())
    assert_eq_int(len(spans), 2, "span count")
    assert_eq_str(_slice(content, spans[0]), '{"a": 1}', "span 0 text")
    assert_eq_str(_slice(content, spans[1]), '{"a": 22}', "span 1 text")


def test_find_line_spans_skips_blank_lines() raises:
    var content = String('{"a": 1}\n\n{"a": 2}\n\n')
    var spans = find_line_spans(content.as_bytes())
    assert_eq_int(len(spans), 2, "span count")
    assert_eq_str(_slice(content, spans[0]), '{"a": 1}', "span 0 text")
    assert_eq_str(_slice(content, spans[1]), '{"a": 2}', "span 1 text")


def test_find_line_spans_no_trailing_newline() raises:
    """A file whose last line has no trailing '\\n' still yields that
    line's span (mirrors read_text's raw content, no assumption of a
    final newline)."""
    var content = String('{"a": 1}\n{"a": 2}')
    var spans = find_line_spans(content.as_bytes())
    assert_eq_int(len(spans), 2, "span count")
    assert_eq_str(_slice(content, spans[1]), '{"a": 2}', "span 1 text")


def test_find_line_spans_empty_buffer_yields_no_spans() raises:
    var content = String("")
    var spans = find_line_spans(content.as_bytes())
    assert_eq_int(len(spans), 0, "span count")


def test_find_line_spans_all_blank_yields_no_spans() raises:
    var content = String("\n\n\n")
    var spans = find_line_spans(content.as_bytes())
    assert_eq_int(len(spans), 0, "span count")


# ── read_ndjson_lines: file-level integration on top of find_line_spans ─────


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
    var result = read_ndjson_lines("/tmp/fhir_arrow_test_lines_blank.ndjson")
    var content = result[0]
    var spans = result[1].copy()
    assert_eq_int(len(spans), 2, "line count")
    assert_eq_str(_slice(content, spans[0]), '{"a": 1}', "line 0 raw text")
    assert_eq_str(_slice(content, spans[1]), '{"a": 2}', "line 1 raw text")


def test_read_ndjson_lines_returns_n_spans_in_order() raises:
    """A well-formed N-line NDJSON file yields N spans, in order, with no
    JSON parsing performed (read_ndjson_lines never parses)."""
    _write(
        "/tmp/fhir_arrow_test_lines_n.ndjson",
        '{"a": 1}\n{"a": 2}\n{"a": 3}\n',
    )
    var result = read_ndjson_lines("/tmp/fhir_arrow_test_lines_n.ndjson")
    var content = result[0]
    var spans = result[1].copy()
    assert_eq_int(len(spans), 3, "line count")
    assert_eq_str(_slice(content, spans[0]), '{"a": 1}', "line 0")
    assert_eq_str(_slice(content, spans[1]), '{"a": 2}', "line 1")
    assert_eq_str(_slice(content, spans[2]), '{"a": 3}', "line 2")


def test_read_ndjson_lines_does_not_reject_invalid_json() raises:
    """`read_ndjson_lines` never parses: a line that wouldn't be valid JSON
    is still returned as-is (as a valid span). Validity is checked later,
    per field, inside fast_shred.mojo's shred_*_fast functions."""
    _write(
        "/tmp/fhir_arrow_test_lines_notjson.ndjson",
        '{"a": 1}\nnot json at all\n{"a": 3}\n',
    )
    var result = read_ndjson_lines("/tmp/fhir_arrow_test_lines_notjson.ndjson")
    var content = result[0]
    var spans = result[1].copy()
    assert_eq_int(len(spans), 3, "line count")
    assert_eq_str(
        _slice(content, spans[1]), "not json at all", "line 1 passed through raw"
    )


def main() raises:
    test_find_line_spans_offsets_correct()
    print("PASS test_find_line_spans_offsets_correct")

    test_find_line_spans_skips_blank_lines()
    print("PASS test_find_line_spans_skips_blank_lines")

    test_find_line_spans_no_trailing_newline()
    print("PASS test_find_line_spans_no_trailing_newline")

    test_find_line_spans_empty_buffer_yields_no_spans()
    print("PASS test_find_line_spans_empty_buffer_yields_no_spans")

    test_find_line_spans_all_blank_yields_no_spans()
    print("PASS test_find_line_spans_all_blank_yields_no_spans")

    test_read_ndjson_lines_rejects_empty_file()
    print("PASS test_read_ndjson_lines_rejects_empty_file")

    test_read_ndjson_lines_skips_blank_lines()
    print("PASS test_read_ndjson_lines_skips_blank_lines")

    test_read_ndjson_lines_returns_n_spans_in_order()
    print("PASS test_read_ndjson_lines_returns_n_spans_in_order")

    test_read_ndjson_lines_does_not_reject_invalid_json()
    print("PASS test_read_ndjson_lines_does_not_reject_invalid_json")

    print("\nAll ndjson tests passed.")
