# chunk_planner.mojo: computes newline-aligned byte-range chunk boundaries
# for the parallel shredding path, in ONE pass over the file.
#
# This is deliberately a separate, single invocation rather than something
# each worker recomputes: the whole point of the byte-range design (see
# ndjson_range_to_feather's docstring in fhir_arrow.mojo) is that only ONE
# process reads the entire file once; every parallel_worker after that
# reads only its own chunk's bytes via seek+read.
#
# Usage: chunk_planner <ndjson_path> <num_chunks>
# Prints num_chunks lines of "<start_byte> <end_byte>", one per chunk, in
# order. The last chunk's end_byte is a value guaranteed to be at or past
# EOF (read() short-reads at EOF rather than erroring, so this is safe).

from std.sys import argv
from ndjson import read_ndjson_lines


def main() raises:
    var args = argv()
    if len(args) < 3:
        print("usage: chunk_planner <ndjson_path> <num_chunks>")
        return

    var ndjson_path = String(args[1])
    var num_chunks = Int(String(args[2]))

    var result = read_ndjson_lines(ndjson_path)
    var spans = result[1].copy()
    var n = len(spans)

    if num_chunks < 1:
        num_chunks = 1
    if num_chunks > n:
        num_chunks = n

    var chunk_size = (n + num_chunks - 1) // num_chunks

    var i = 0
    while i < n:
        var j = i + chunk_size
        if j > n:
            j = n
        var start_byte = spans[i][0]
        # End at the next chunk's first byte, or a past-EOF sentinel for
        # the last chunk (read() at EOF just returns fewer bytes).
        var end_byte: Int
        if j < n:
            end_byte = spans[j][0]
        else:
            end_byte = spans[n - 1][1] + 1
        print(String(start_byte) + " " + String(end_byte))
        i = j
