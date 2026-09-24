# ndjson.mojo: newline-delimited JSON reader.
#
# read_ndjson(path) -> List[JsonValue], one parsed value per non-blank line.
# Used to read Bulk FHIR $export NDJSON files (one resource per line).

from std.pathlib import Path
from json import JsonValue, parse_json


def read_ndjson(path: String) raises -> List[JsonValue]:
    """Read an NDJSON file, skipping blank lines. Raises if the file has no
    non-blank lines, or if a line fails to parse as JSON (error message
    includes the 1-based line number)."""
    var content = Path(path).read_text()
    var raw_lines = content.split("\n")

    var rows = List[JsonValue]()
    for i in range(len(raw_lines)):
        var line = String(raw_lines[i])
        if line.byte_length() == 0:
            continue
        try:
            rows.append(parse_json(line))
        except e:
            raise Error(
                "ndjson: read_ndjson: line "
                + String(i + 1)
                + ": "
                + String(e)
            )

    if len(rows) == 0:
        raise Error("ndjson: read_ndjson: no records found in " + path)

    return rows^
