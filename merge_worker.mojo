# merge_worker.mojo: CLI entry point that combines N chunk Feather files
# (produced by parallel_worker.mojo, one per NDJSON chunk, same schema, in
# chunk order) into one Feather file with all of their RecordBatches — see
# fhir_arrow.mojo's merge_feathers for what this actually does.
#
# Usage: merge_worker <out_path> <chunk_path_0> <chunk_path_1> ...

from std.sys import argv
from fhir_arrow import merge_feathers


def main() raises:
    var args = argv()
    if len(args) < 3:
        print("usage: merge_worker <out_path> <chunk_path_0> <chunk_path_1> ...")
        return

    var out_path = String(args[1])
    var paths = List[String]()
    for i in range(2, len(args)):
        paths.append(String(args[i]))

    merge_feathers(paths, out_path)
