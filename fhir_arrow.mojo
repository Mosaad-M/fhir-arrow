# fhir_arrow.mojo — column builders + Feather writers for shredded FHIR rows.
#
# Uses arrow.mojo's legacy ArrowType/ArrowField/ArrowSchema/ArrowArray/
# RecordBatch/encode_arrow_file API (proven end-to-end by csv_arrow.mojo) —
# the newer Phase 1/2 typed-builder API (dtypes/arrays/builders.mojo) has no
# bridge to file encoding yet.

from std.pathlib import Path
from arrow import (
    ArrowType, ArrowField, ArrowSchema, ArrowArray, RecordBatch,
    encode_arrow_file,
)
from flatbuffers import write_i32_le, write_f64_le
from ndjson import read_ndjson
from resources import (
    PatientRow, shred_patient,
    ObservationRow, shred_observation,
    ConditionRow, shred_condition,
)


# ── Bit packing (shared by validity bitmaps and Bool value buffers — both are
#    packed 1 bit/element, LSB-first, per Arrow's format) ────────────────────


def _pack_bits(bits: List[Bool]) -> List[UInt8]:
    var length = len(bits)
    var n_bytes = (length + 7) // 8
    var packed = List[UInt8]()
    for _ in range(n_bytes):
        packed.append(UInt8(0))
    for i in range(length):
        if bits[i]:
            packed[i // 8] = packed[i // 8] | (UInt8(1) << UInt8(i % 8))
    return packed^


# ── Column builders ───────────────────────────────────────────────────────────


def build_string_column(values: List[Optional[String]]) raises -> ArrowArray:
    """Nullable Utf8 column from a list of optional strings."""
    var length = len(values)
    var null_bits = List[Bool]()
    var null_count = 0
    for i in range(length):
        if values[i]:
            null_bits.append(True)
        else:
            null_bits.append(False)
            null_count += 1

    var validity = List[UInt8]()
    if null_count > 0:
        validity = _pack_bits(null_bits)

    var offsets = List[UInt8]()
    for _ in range((length + 1) * 4):
        offsets.append(UInt8(0))
    write_i32_le(offsets, 0, Int32(0))

    var value_bytes = List[UInt8]()
    var cur = 0
    for i in range(length):
        if values[i]:
            var sb = values[i].value().as_bytes()
            for j in range(len(sb)):
                value_bytes.append(sb[j])
            cur += len(sb)
        write_i32_le(offsets, (i + 1) * 4, Int32(cur))

    return ArrowArray(
        ArrowType.utf8(), length, null_count, validity, offsets, value_bytes
    )


def build_required_string_column(values: List[String]) raises -> ArrowArray:
    """Non-nullable Utf8 column (used for `id`, which is always required)."""
    var opt_values = List[Optional[String]]()
    for i in range(len(values)):
        opt_values.append(Optional[String](values[i]))
    return build_string_column(opt_values)


def build_float64_column(values: List[Optional[Float64]]) raises -> ArrowArray:
    """Nullable Float64 column from a list of optional floats."""
    var length = len(values)
    var null_bits = List[Bool]()
    var null_count = 0
    for i in range(length):
        if values[i]:
            null_bits.append(True)
        else:
            null_bits.append(False)
            null_count += 1

    var validity = List[UInt8]()
    if null_count > 0:
        validity = _pack_bits(null_bits)

    var value_bytes = List[UInt8]()
    for _ in range(length * 8):
        value_bytes.append(UInt8(0))
    for i in range(length):
        var f = Float64(0.0)
        if values[i]:
            f = values[i].value()
        write_f64_le(value_bytes, i * 8, f)

    return ArrowArray(
        ArrowType.float_(2), length, null_count, validity, List[UInt8](), value_bytes
    )


def build_bool_column(values: List[Optional[Bool]]) raises -> ArrowArray:
    """Nullable Bool column. Values buffer is packed bits, LSB-first (same
    scheme as the validity bitmap, per arrow.mojo's decode/encode)."""
    var length = len(values)
    var null_bits = List[Bool]()
    var value_bits = List[Bool]()
    var null_count = 0
    for i in range(length):
        if values[i]:
            null_bits.append(True)
            value_bits.append(values[i].value())
        else:
            null_bits.append(False)
            value_bits.append(False)
            null_count += 1

    var validity = List[UInt8]()
    if null_count > 0:
        validity = _pack_bits(null_bits)

    var value_bytes = _pack_bits(value_bits)

    return ArrowArray(
        ArrowType.bool_(), length, null_count, validity, List[UInt8](), value_bytes
    )
