# ndjson.mojo: newline-delimited JSON reader.
#
# find_line_spans(content) -> List[Tuple[Int, Int]], the (start, end) byte
# offset of each non-blank '\n'-delimited line in a buffer.
# read_ndjson_lines(path) -> (content, spans): reads the file once and
# returns the whole content plus one span per non-blank line. No per-line
# String is allocated: callers slice content.as_bytes()[start:end] directly
# (e.g. into fast_shred.mojo's shred_*_fast functions, which take a byte
# Span), so a large NDJSON file no longer costs one String allocation per
# line just to be read. JSON parsing happens inside fast_shred's
# shred_*_fast functions, not here: this module never builds a JsonValue
# tree at all.
#
# find_line_spans uses String.find() to locate each '\n' rather than a
# hand-rolled byte-by-byte scan: measured directly against a 266K-line
# real file, a manual `while i < n: if b[i] == LF` loop took ~450ms versus
# ~17ms for a find()-in-a-loop scan — a ~25x difference, evidently because
# the stdlib's search is vectorized and a naive per-byte Span index loop
# is not (at least under `mojo run`, not `mojo build -O`). Confirmed by
# direct side-by-side measurement, not assumed: don't hand-roll a byte
# scan here again without re-benchmarking against find() first.


from std.pathlib import Path


def find_line_spans(content: String) raises -> List[Tuple[Int, Int]]:
    """Scan `content` for '\\n'-delimited line boundaries, skipping
    zero-length (blank) lines. Returns (start, end) byte-offset pairs into
    `content`, in order. Allocates only the result list itself — no
    per-line copy of the underlying bytes."""
    var n = content.byte_length()
    var spans = List[Tuple[Int, Int]]()
    var pos = 0
    while pos < n:
        var idx = content.find("\n", pos)
        var end = idx if idx >= 0 else n
        if end > pos:
            spans.append(Tuple[Int, Int](pos, end))
        if idx < 0:
            break
        pos = idx + 1
    return spans^


def read_ndjson_lines(path: String) raises -> Tuple[String, List[Tuple[Int, Int]]]:
    """Read an NDJSON file once. Returns (content, spans), one span per
    non-blank line, in order. Raises if the file has no non-blank lines."""
    var content = Path(path).read_text()
    var spans = find_line_spans(content)

    if len(spans) == 0:
        raise Error("ndjson: read_ndjson_lines: no records found in " + path)

    return Tuple[String, List[Tuple[Int, Int]]](content^, spans^)
