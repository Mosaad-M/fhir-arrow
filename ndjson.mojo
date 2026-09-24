# ndjson.mojo: newline-delimited JSON reader.
#
# read_ndjson_lines(path) -> List[String], one raw line per non-blank line.
# Used to read Bulk FHIR $export NDJSON files (one resource per line) for
# the zero-tree fast_shred path: JSON parsing happens inside fast_shred's
# shred_*_fast functions, not here, so this module never builds a JsonValue
# tree at all.

from std.pathlib import Path


def read_ndjson_lines(path: String) raises -> List[String]:
    """Read an NDJSON file, skipping blank lines, WITHOUT parsing JSON.
    Returns one raw line String per non-blank line, in order. Raises if
    the file has no non-blank lines. Used by the fast (zero-tree) shredder
    path in fast_shred.mojo, which scans each line's bytes directly."""
    var content = Path(path).read_text()
    var raw_lines = content.split("\n")

    var lines = List[String]()
    for i in range(len(raw_lines)):
        var line = String(raw_lines[i])
        if line.byte_length() == 0:
            continue
        lines.append(line)

    if len(lines) == 0:
        raise Error("ndjson: read_ndjson_lines: no records found in " + path)

    return lines^
