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
    # Sized read, not Path.read_text(): an unsized read grows its buffer as
    # it goes and peaks at several times the file size; reading exactly the
    # file's size peaks at 2x only transiently, leaving 1x resident.
    var f = open(path, "r")
    var size = Int(f.seek(0, 2))
    _ = f.seek(0)
    var content = f.read(size)
    f.close()
    var spans = find_line_spans(content)

    if len(spans) == 0:
        raise Error("ndjson: read_ndjson_lines: no records found in " + path)

    return Tuple[String, List[Tuple[Int, Int]]](content^, spans^)


def _find_next_line_boundary(
    path: String, target_offset: Int, window_size: Int = 65536
) raises -> Int:
    """Seeks to `target_offset` (need not be on a line boundary) and scans
    forward in `window_size` reads for the next '\\n', WITHOUT reading the
    whole file: the streaming path's chunk-boundary primitive (unlike
    chunk_planner.mojo, which reads the whole file up front). Returns the
    byte offset right after that newline, i.e. the start of the next line.
    If no further newline exists, returns the file size."""
    var f = open(path, "r")
    _ = f.seek(target_offset)
    var pos = target_offset
    while True:
        var chunk = f.read(window_size)
        if chunk.byte_length() == 0:
            f.close()
            return pos
        var idx = chunk.find("\n")
        if idx >= 0:
            f.close()
            return pos + idx + 1
        pos += chunk.byte_length()


def _read_ndjson_range_spans(
    path: String, start_byte: Int, end_byte: Int
) raises -> Tuple[String, List[Tuple[Int, Int]]]:
    """Reads exactly [start_byte, end_byte) via seek+read and finds the line
    spans in it, returning an empty span list (not an error) for a range of
    only blank lines. read_ndjson_range adds the "no records" check; the
    streaming path calls this directly, since an all-blank chunk is fine
    there."""
    var f = open(path, "r")
    _ = f.seek(start_byte)
    var content = f.read(end_byte - start_byte)
    f.close()
    var spans = find_line_spans(content)
    return Tuple[String, List[Tuple[Int, Int]]](content^, spans^)


def read_ndjson_range(
    path: String, start_byte: Int, end_byte: Int
) raises -> Tuple[String, List[Tuple[Int, Int]]]:
    """Like read_ndjson_lines, but reads only [start_byte, end_byte) of the
    file via seek+read instead of the whole file. Used by the parallel
    shredding path (parallel_worker.mojo): each worker process reads only
    its own chunk's bytes directly from the ORIGINAL file, no whole-file
    read and no physical file copy. Caller (chunk_planner.mojo) is
    responsible for aligning start_byte/end_byte to line boundaries -- this
    function doesn't adjust for misaligned input, it just reads exactly the
    given byte range and finds line spans within it."""
    var result = _read_ndjson_range_spans(path, start_byte, end_byte)
    if len(result[1]) == 0:
        raise Error(
            "ndjson: read_ndjson_range: no records found in "
            + path
            + " ["
            + String(start_byte)
            + ", "
            + String(end_byte)
            + ")"
        )

    return result^
