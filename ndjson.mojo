# ndjson.mojo: newline-delimited JSON reader.
#
# find_line_spans(b) -> List[Tuple[Int, Int]], the (start, end) byte offset
# of each non-blank '\n'-delimited line in a buffer.
# read_ndjson_lines(path) -> (content, spans): reads the file once and
# returns the whole content plus one span per non-blank line. No per-line
# String is allocated: callers slice content.as_bytes()[start:end] directly
# (e.g. into fast_shred.mojo's shred_*_fast functions, which take a byte
# Span), so a large NDJSON file no longer costs one String allocation per
# line just to be read. JSON parsing happens inside fast_shred's
# shred_*_fast functions, not here: this module never builds a JsonValue
# tree at all.

from std.pathlib import Path

comptime _LF = UInt8(10)  # ord("\n")


def find_line_spans(b: Span[UInt8, _]) raises -> List[Tuple[Int, Int]]:
    """Scan a byte buffer for '\\n'-delimited line boundaries, skipping
    zero-length (blank) lines. Returns (start, end) byte-offset pairs into
    `b`, in order. Allocates only the result list itself — no per-line
    copy of the underlying bytes."""
    var n = len(b)
    var spans = List[Tuple[Int, Int]]()
    var line_start = 0
    var i = 0
    while i < n:
        if b[i] == _LF:
            if i > line_start:
                spans.append(Tuple[Int, Int](line_start, i))
            line_start = i + 1
        i += 1
    if line_start < n:
        spans.append(Tuple[Int, Int](line_start, n))
    return spans^


def read_ndjson_lines(path: String) raises -> Tuple[String, List[Tuple[Int, Int]]]:
    """Read an NDJSON file once. Returns (content, spans), one span per
    non-blank line, in order. Raises if the file has no non-blank lines."""
    var content = Path(path).read_text()
    var spans = find_line_spans(content.as_bytes())

    if len(spans) == 0:
        raise Error("ndjson: read_ndjson_lines: no records found in " + path)

    return Tuple[String, List[Tuple[Int, Int]]](content^, spans^)
