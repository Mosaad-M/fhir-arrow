# fast_shred.mojo: zero-tree FHIR resource shredders.
#
# Unlike resources.mojo (which parses each NDJSON line into a full JsonValue
# tree via json.mojo before reading a handful of fields out of it), this
# module scans each line's raw bytes directly and only ever decodes the
# specific fields the v0 schema (see resources.mojo/README) cares about.
# Everything else is skipped in O(bytes) without allocating a representation
# for it.
#
# Two shared primitives do all the work:
#   _skip_value(b, i) -> index just past the JSON value starting at i.
#   _find_key(b, obj_start, key) -> value_start index of `key` among the
#     DIRECT (non-nested) keys of the object starting at obj_start, or None.
# Everything else (name[0].family, code.coding[0].code, subject.reference,
# the polymorphic valueQuantity/valueString, ...) is built from repeated
# calls to these two, matching resources.mojo's field list exactly: no
# generic path-expression engine on top of them.
#
# Trade-off, accepted and documented in the README: this hand-rolled scanner
# is less forgiving of malformed/unexpected JSON shapes than json.mojo's
# general tree parser. It's the "narrow shredder" this project was always
# meant to be, not a general-purpose FHIR parser.

from resources import PatientRow, ObservationRow, ConditionRow


# ── Byte constants ────────────────────────────────────────────────────────────

comptime _QUOTE = UInt8(ord('"'))
comptime _BACKSLASH = UInt8(ord("\\"))
comptime _LBRACE = UInt8(ord("{"))
comptime _RBRACE = UInt8(ord("}"))
comptime _LBRACKET = UInt8(ord("["))
comptime _RBRACKET = UInt8(ord("]"))
comptime _COMMA = UInt8(ord(","))
comptime _COLON = UInt8(ord(":"))
comptime _SPACE = UInt8(ord(" "))
comptime _TAB = UInt8(ord("\t"))
comptime _CR = UInt8(ord("\r"))
comptime _LF = UInt8(ord("\n"))
comptime _LOWER_U = UInt8(ord("u"))
comptime _LOWER_T = UInt8(ord("t"))
comptime _LOWER_F = UInt8(ord("f"))


def _is_ws(c: UInt8) -> Bool:
    return c == _SPACE or c == _TAB or c == _CR or c == _LF


# ── SIMD-accelerated candidate search ────────────────────────────────────────
#
# _skip_string and _skip_value both used to advance one byte at a time while
# nothing structurally interesting was happening ("else: i += 1"). These two
# helpers replace that "boring byte, keep going" branch with a bulk
# vectorized search for the FIRST matching candidate; the scalar logic that
# decides what a candidate byte MEANS (escape handling in _skip_string, depth
# counting in _skip_value) is untouched below.
#
# A batch-extraction variant of this (find ALL hits in one chunk load, not
# just the first, using SIMD.eq()+`|` for a real elementwise mask) was tried
# and measured directly against this repo's own benchmark — see
# tasks/lessons.md for the full writeup. It was a real regression, not just
# underwhelming: 1.5-9x SLOWER end to end, because the mandatory full-32-lane
# extraction scan it needs (to find every hit, not just the first) costs more
# than an early-exit single-hit scan for the common case, which for real FHIR
# JSON is a single hit per call (a string's own closing quote, a field's
# structural delimiter) — batching only pays off when a chunk holds several
# hits worth amortizing the scan over, and that's the exception here, not the
# rule. Reverted back to this single-hit early-exit design after confirming
# that with the same real Synthea data and the same benchmark.
#
# SIMD_WIDTH = 32 (AVX2, 256-bit / 8-bit lanes) matches 1brc_arrow's choice,
# already validated safe for this repo's declared linux-64/osx-arm64
# platforms (GitHub's ubuntu-22.04 runners have AVX2 but not AVX-512).

comptime _SIMD_WIDTH = 32


def _simd_find_first2(b: Span[UInt8, _], start: Int, t0: UInt8, t1: UInt8) raises -> Int:
    """First occurrence of t0 or t1 in b[start:], early-exiting as soon as
    a match is found within a chunk (does NOT batch-extract every hit).
    Used by _skip_string specifically: a string almost always has exactly
    one relevant hit per call (its own closing quote, no escapes) — for
    that common case, an unconditional full-chunk lane scan (as
    _load_chunk_hits2 does, needed to find EVERY hit) costs strictly more
    than finding just the first and stopping, since it always walks all
    _SIMD_WIDTH lanes regardless of how early the match is. Measured
    directly: using the batch extractor here made the whole pipeline
    3-8x SLOWER, not faster — see lessons.md. _skip_value keeps the batch
    extractor (_load_chunk_hits3) since its own multi-hit chunks (quote/
    open/close close together while scanning past a skipped object) are
    common enough there to be worth it; _skip_string's are not."""
    var n = len(b)
    var ptr = b.unsafe_ptr()
    var v0 = SIMD[DType.uint8, _SIMD_WIDTH](t0)
    var v1 = SIMD[DType.uint8, _SIMD_WIDTH](t1)
    var pos = start
    while pos + _SIMD_WIDTH <= n:
        var chunk = ptr.unsafe_offset(pos).unsafe_load[width=_SIMD_WIDTH]()
        var m = min(chunk ^ v0, chunk ^ v1)
        if m.reduce_min() == UInt8(0):
            for j in range(_SIMD_WIDTH):
                if chunk[j] == t0 or chunk[j] == t1:
                    return pos + j
        pos += _SIMD_WIDTH
    while pos < n:
        var c = b[pos]
        if c == t0 or c == t1:
            return pos
        pos += 1
    return n


def _simd_find_first3(
    b: Span[UInt8, _], start: Int, t0: UInt8, t1: UInt8, t2: UInt8
) raises -> Int:
    """Same as _simd_find_first2 but for three target bytes (used by
    _skip_value's bracket-depth loop: quote/open/close)."""
    var n = len(b)
    var ptr = b.unsafe_ptr()
    var v0 = SIMD[DType.uint8, _SIMD_WIDTH](t0)
    var v1 = SIMD[DType.uint8, _SIMD_WIDTH](t1)
    var v2 = SIMD[DType.uint8, _SIMD_WIDTH](t2)
    var pos = start
    while pos + _SIMD_WIDTH <= n:
        var chunk = ptr.unsafe_offset(pos).unsafe_load[width=_SIMD_WIDTH]()
        var m = min(min(chunk ^ v0, chunk ^ v1), chunk ^ v2)
        if m.reduce_min() == UInt8(0):
            for j in range(_SIMD_WIDTH):
                if chunk[j] == t0 or chunk[j] == t1 or chunk[j] == t2:
                    return pos + j
        pos += _SIMD_WIDTH
    while pos < n:
        var c = b[pos]
        if c == t0 or c == t1 or c == t2:
            return pos
        pos += 1
    return n


# ── _skip_string: i must point exactly at the opening quote ─────────────────


def _skip_string(b: Span[UInt8, _], start: Int) raises -> Int:
    var n = len(b)
    var i = start + 1  # skip opening quote
    while i < n:
        i = _simd_find_first2(b, i, _QUOTE, _BACKSLASH)
        if i >= n:
            break
        var c = b[i]
        if c == _BACKSLASH:
            i += 1
            if i >= n:
                raise Error("fast_shred: _skip_string: unterminated escape")
            if b[i] == _LOWER_U:
                i += 5  # 'u' + 4 hex digits
            else:
                i += 1
        else:  # c == _QUOTE
            return i + 1
    raise Error("fast_shred: _skip_string: unterminated string starting at " + String(start))


# ── _skip_value ────────────────────────────────────────────────────────────


def _skip_value(b: Span[UInt8, _], start: Int) raises -> Int:
    """Given the index of the start of a JSON value (leading whitespace
    tolerated), return the index just past that value. Never allocates."""
    var n = len(b)
    var i = start
    while i < n and _is_ws(b[i]):
        i += 1
    if i >= n:
        raise Error("fast_shred: _skip_value: unexpected end of input")

    var c = b[i]
    if c == _QUOTE:
        return _skip_string(b, i)

    if c == _LBRACE or c == _LBRACKET:
        var open_ = c
        var close = _RBRACE if c == _LBRACE else _RBRACKET
        var depth = 1
        i += 1
        while i < n and depth > 0:
            i = _simd_find_first3(b, i, _QUOTE, open_, close)
            if i >= n:
                break
            var d = b[i]
            if d == _QUOTE:
                i = _skip_string(b, i)
            elif d == open_:
                depth += 1
                i += 1
            else:  # d == close
                depth -= 1
                i += 1
        if depth != 0:
            raise Error("fast_shred: _skip_value: unterminated object/array")
        return i

    # number / true / false / null: scan to the next structural delimiter.
    while i < n:
        var d = b[i]
        if d == _COMMA or d == _RBRACE or d == _RBRACKET or _is_ws(d):
            break
        i += 1
    return i


# ── _find_key ────────────────────────────────────────────────────────────────


def _bytes_eq_str(b: Span[UInt8, _], start: Int, end: Int, key: String) raises -> Bool:
    var kb = key.as_bytes()
    if end - start != len(kb):
        return False
    for j in range(len(kb)):
        if b[start + j] != kb[j]:
            return False
    return True


def _find_key(b: Span[UInt8, _], obj_start: Int, key: String) raises -> Optional[Int]:
    """Scan the direct keys of the object starting at obj_start (index of
    '{'). Returns the value's start index for the first matching key, or
    None if the object closes without one. Order-independent; skips
    non-matching values via _skip_value without allocating anything for
    them."""
    var n = len(b)
    var i = obj_start
    while i < n and _is_ws(b[i]):
        i += 1
    if i >= n or b[i] != _LBRACE:
        raise Error("fast_shred: _find_key: expected '{' at position " + String(obj_start))
    i += 1  # skip '{'

    while True:
        while i < n and (_is_ws(b[i]) or b[i] == _COMMA):
            i += 1
        if i >= n:
            raise Error("fast_shred: _find_key: unterminated object")
        if b[i] == _RBRACE:
            return Optional[Int](None)
        if b[i] != _QUOTE:
            raise Error("fast_shred: _find_key: expected '\"' at key position " + String(i))

        var key_start = i
        var key_end = _skip_string(b, i)  # index just past closing quote

        var j = key_end
        while j < n and _is_ws(b[j]):
            j += 1
        if j >= n or b[j] != _COLON:
            raise Error("fast_shred: _find_key: expected ':' after key at " + String(key_end))
        j += 1
        while j < n and _is_ws(b[j]):
            j += 1
        var value_start = j

        # Compare the key text (excluding the surrounding quotes) to `key`.
        if _bytes_eq_str(b, key_start + 1, key_end - 1, key):
            return Optional[Int](value_start)

        i = _skip_value(b, value_start)


# ── _find_keys: single-pass multi-key lookup ─────────────────────────────────
#
# _find_key re-scans an object from the start on every call. Every shredder
# below used to call it repeatedly against the *same* object (e.g. 6 times
# for Observation's top level), re-walking and re-skipping every earlier
# key's value from scratch each time. _find_keys walks an object's direct
# keys exactly once and resolves an arbitrary set of wanted keys in that
# single pass, early-exiting once every slot has been filled.


def _find_keys(
    b: Span[UInt8, _], obj_start: Int, keys: List[String]
) raises -> List[Optional[Int]]:
    """Scan the direct keys of the object starting at obj_start (index of
    '{') once, resolving the value_start index for every name in `keys` in
    a single pass. Returns a list the same length/order as `keys`; a slot
    is None if that key never appears. Order-independent (scans whatever
    key order the object actually has); skips non-matching values via
    _skip_value without allocating anything for them; stops scanning as
    soon as every requested key has been found."""
    var n_keys = len(keys)
    var results = List[Optional[Int]](capacity=n_keys)
    for _ in range(n_keys):
        results.append(Optional[Int](None))
    var remaining = n_keys

    var n = len(b)
    var i = obj_start
    while i < n and _is_ws(b[i]):
        i += 1
    if i >= n or b[i] != _LBRACE:
        raise Error("fast_shred: _find_keys: expected '{' at position " + String(obj_start))
    i += 1  # skip '{'

    while remaining > 0:
        while i < n and (_is_ws(b[i]) or b[i] == _COMMA):
            i += 1
        if i >= n:
            raise Error("fast_shred: _find_keys: unterminated object")
        if b[i] == _RBRACE:
            break
        if b[i] != _QUOTE:
            raise Error("fast_shred: _find_keys: expected '\"' at key position " + String(i))

        var key_start = i
        var key_end = _skip_string(b, i)  # index just past closing quote

        var j = key_end
        while j < n and _is_ws(b[j]):
            j += 1
        if j >= n or b[j] != _COLON:
            raise Error("fast_shred: _find_keys: expected ':' after key at " + String(key_end))
        j += 1
        while j < n and _is_ws(b[j]):
            j += 1
        var value_start = j

        for k in range(n_keys):
            if not results[k] and _bytes_eq_str(b, key_start + 1, key_end - 1, keys[k]):
                results[k] = Optional[Int](value_start)
                remaining -= 1
                break

        i = _skip_value(b, value_start)

    return results^


# ── _first_array_element ──────────────────────────────────────────────────────


def _first_array_element(b: Span[UInt8, _], arr_start: Int) raises -> Optional[Int]:
    """arr_start must point at '['. Returns the start index of the first
    element (past any leading whitespace), or None if the array is empty."""
    var n = len(b)
    var i = arr_start
    while i < n and _is_ws(b[i]):
        i += 1
    if i >= n or b[i] != _LBRACKET:
        raise Error("fast_shred: _first_array_element: expected '[' at position " + String(arr_start))
    i += 1  # skip '['
    while i < n and _is_ws(b[i]):
        i += 1
    if i >= n:
        raise Error("fast_shred: _first_array_element: unterminated array")
    if b[i] == _RBRACKET:
        return Optional[Int](None)
    return Optional[Int](i)


# ── Scalar extraction ──────────────────────────────────────────────────────────
# Unlike _skip_string (which only needs to find the end of a string), these
# actually decode the value. String escape handling mirrors json.mojo's
# _parse_string exactly, including the '?' placeholder for \uXXXX escapes,
# for behavioral consistency with the reference implementation.


def _extract_string(b: Span[UInt8, _], start: Int) raises -> String:
    """start must point at the opening quote.

    Fast path: most FHIR field values (ids, LOINC codes, ISO dates) never
    contain an escape. Scan for the closing quote checking only for a
    backslash; if none is seen, the string's exact length is already known
    (no escapes means byte count == char count), so the result buffer is
    pre-sized once and bulk-copied in a second pass, instead of growing via
    `.append()` on every byte the way the escape-handling loop below has
    to. Falls back to the byte-by-byte escape-decoding loop the moment a
    backslash is seen (same output as before this fast path existed — this
    is a performance-only change, not a behavior change)."""
    var n = len(b)
    var j = start + 1
    while j < n:
        var c = b[j]
        if c == _QUOTE:
            var length = j - (start + 1)
            var result = List[UInt8](capacity=length)
            for k in range(start + 1, j):
                result.append(b[k])
            return String(unsafe_from_utf8=result^)
        elif c == _BACKSLASH:
            break
        j += 1
    return _extract_string_escaped(b, start)


def _extract_string_escaped(b: Span[UInt8, _], start: Int) raises -> String:
    """Byte-by-byte escape-decoding fallback for _extract_string, used once
    a backslash has been seen. start must point at the opening quote."""
    var n = len(b)
    var i = start + 1
    var result = List[UInt8](capacity=32)
    while i < n:
        var c = b[i]
        if c == _QUOTE:
            return String(unsafe_from_utf8=result^)
        elif c == _BACKSLASH:
            i += 1
            if i >= n:
                raise Error("fast_shred: _extract_string: unterminated escape")
            var esc = b[i]
            if esc == _QUOTE:
                result.append(_QUOTE)
            elif esc == _BACKSLASH:
                result.append(_BACKSLASH)
            elif esc == UInt8(ord("/")):
                result.append(UInt8(ord("/")))
            elif esc == UInt8(ord("n")):
                result.append(_LF)
            elif esc == UInt8(ord("r")):
                result.append(_CR)
            elif esc == UInt8(ord("t")):
                result.append(_TAB)
            elif esc == UInt8(ord("b")):
                result.append(UInt8(8))
            elif esc == UInt8(ord("f")):
                result.append(UInt8(12))
            elif esc == _LOWER_U:
                i += 4  # skip 4 hex digits (i itself advances past 'u' below)
                result.append(UInt8(ord("?")))
            else:
                result.append(esc)
            i += 1
        else:
            result.append(c)
            i += 1
    raise Error("fast_shred: _extract_string: unterminated string starting at " + String(start))


def _extract_number(b: Span[UInt8, _], start: Int) raises -> Float64:
    """start must point at the first character of a JSON number."""
    var end = _skip_value(b, start)
    var num_bytes = List[UInt8](capacity=end - start)
    for i in range(start, end):
        num_bytes.append(b[i])
    var s = String(unsafe_from_utf8=num_bytes^)
    return Float64(s)


def _extract_bool(b: Span[UInt8, _], start: Int) raises -> Bool:
    """start must point at the 't' of true or 'f' of false."""
    if b[start] == _LOWER_T:
        return True
    elif b[start] == _LOWER_F:
        return False
    raise Error("fast_shred: _extract_bool: expected true/false at " + String(start))


# ── Shared: first coding[0] of a `code` CodeableConcept object already ──────
#    located by the caller (mirrors resources.mojo's _coding0) ─────────────


def _coding0_at(b: Span[UInt8, _], code_start: Int) raises -> Optional[Int]:
    """Given the start of a `code` object (already found by the caller,
    typically via a batched _find_keys pass), return the start index of
    code.coding[0], or None. Takes code_start directly rather than
    re-finding "code" from scratch, since the caller already has it."""
    var coding_start = _find_key(b, code_start, "coding")
    if not coding_start:
        return Optional[Int](None)
    return _first_array_element(b, coding_start.value())


# ── Patient ──────────────────────────────────────────────────────────────────


def shred_patient_fast(b: Span[UInt8, _]) raises -> PatientRow:
    """Zero-tree equivalent of resources.mojo's shred_patient: same v0
    field scope, same behavior on missing/optional fields. Resolves all
    five top-level fields in a single pass over the object via _find_keys,
    instead of one full re-scan per field. Takes the record's raw bytes
    directly (a slice of the whole NDJSON file's buffer) rather than an
    owned line String, so reading a large file no longer costs one String
    allocation per line just to hand it to the shredder."""
    var top_keys: List[String] = ["id", "gender", "birthDate", "name", "deceasedBoolean"]
    var top = _find_keys(b, 0, top_keys)

    if not top[0]:
        raise Error("fast_shred: shred_patient_fast: missing required field 'id'")
    var id = _extract_string(b, top[0].value())

    var gender = Optional[String](None)
    if top[1]:
        gender = Optional[String](_extract_string(b, top[1].value()))

    var birth_date = Optional[String](None)
    if top[2]:
        birth_date = Optional[String](_extract_string(b, top[2].value()))

    var family_name = Optional[String](None)
    var given_name = Optional[String](None)
    if top[3]:
        var name0_start = _first_array_element(b, top[3].value())
        if name0_start:
            var name_keys: List[String] = ["family", "given"]
            var name_fields = _find_keys(b, name0_start.value(), name_keys)
            if name_fields[0]:
                family_name = Optional[String](_extract_string(b, name_fields[0].value()))
            if name_fields[1]:
                var given0_start = _first_array_element(b, name_fields[1].value())
                if given0_start:
                    given_name = Optional[String](_extract_string(b, given0_start.value()))

    var deceased = Optional[Bool](None)
    if top[4]:
        deceased = Optional[Bool](_extract_bool(b, top[4].value()))

    return PatientRow(id, gender, birth_date, family_name, given_name, deceased)


# ── Observation ──────────────────────────────────────────────────────────────


def shred_observation_fast(b: Span[UInt8, _]) raises -> ObservationRow:
    """Zero-tree equivalent of resources.mojo's shred_observation. Resolves
    all seven top-level fields in a single pass via _find_keys, instead of
    six separate full re-scans of the same object. Takes the record's raw
    bytes directly, see shred_patient_fast."""
    var top_keys: List[String] = [
        "id", "subject", "code", "status", "effectiveDateTime",
        "valueQuantity", "valueString",
    ]
    var top = _find_keys(b, 0, top_keys)

    if not top[0]:
        raise Error("fast_shred: shred_observation_fast: missing required field 'id'")
    var id = _extract_string(b, top[0].value())

    var patient_ref = Optional[String](None)
    if top[1]:
        var ref_start = _find_key(b, top[1].value(), "reference")
        if ref_start:
            patient_ref = Optional[String](_extract_string(b, ref_start.value()))

    var code = Optional[String](None)
    var code_system = Optional[String](None)
    var code_display = Optional[String](None)
    if top[2]:
        var coding0_start = _coding0_at(b, top[2].value())
        if coding0_start:
            var coding_keys: List[String] = ["code", "system", "display"]
            var coding_fields = _find_keys(b, coding0_start.value(), coding_keys)
            if coding_fields[0]:
                code = Optional[String](_extract_string(b, coding_fields[0].value()))
            if coding_fields[1]:
                code_system = Optional[String](_extract_string(b, coding_fields[1].value()))
            if coding_fields[2]:
                code_display = Optional[String](_extract_string(b, coding_fields[2].value()))

    var status = Optional[String](None)
    if top[3]:
        status = Optional[String](_extract_string(b, top[3].value()))

    var effective_datetime = Optional[String](None)
    if top[4]:
        effective_datetime = Optional[String](_extract_string(b, top[4].value()))

    var value_quantity = Optional[Float64](None)
    var value_unit = Optional[String](None)
    var value_string = Optional[String](None)
    if top[5]:
        var vq_keys: List[String] = ["value", "unit"]
        var vq_fields = _find_keys(b, top[5].value(), vq_keys)
        if vq_fields[0]:
            value_quantity = Optional[Float64](_extract_number(b, vq_fields[0].value()))
        if vq_fields[1]:
            value_unit = Optional[String](_extract_string(b, vq_fields[1].value()))
    elif top[6]:
        value_string = Optional[String](_extract_string(b, top[6].value()))

    return ObservationRow(
        id,
        patient_ref,
        code,
        code_system,
        code_display,
        status,
        effective_datetime,
        value_quantity,
        value_unit,
        value_string,
    )


# ── Condition ────────────────────────────────────────────────────────────────


def shred_condition_fast(b: Span[UInt8, _]) raises -> ConditionRow:
    """Zero-tree equivalent of resources.mojo's shred_condition. Resolves
    all six top-level fields in a single pass via _find_keys, instead of
    six separate full re-scans of the same object. Takes the record's raw
    bytes directly, see shred_patient_fast."""
    var top_keys: List[String] = [
        "id", "subject", "code", "clinicalStatus", "onsetDateTime", "recordedDate",
    ]
    var top = _find_keys(b, 0, top_keys)

    if not top[0]:
        raise Error("fast_shred: shred_condition_fast: missing required field 'id'")
    var id = _extract_string(b, top[0].value())

    var patient_ref = Optional[String](None)
    if top[1]:
        var ref_start = _find_key(b, top[1].value(), "reference")
        if ref_start:
            patient_ref = Optional[String](_extract_string(b, ref_start.value()))

    var code = Optional[String](None)
    var code_display = Optional[String](None)
    if top[2]:
        var coding0_start = _coding0_at(b, top[2].value())
        if coding0_start:
            var coding_keys: List[String] = ["code", "display"]
            var coding_fields = _find_keys(b, coding0_start.value(), coding_keys)
            if coding_fields[0]:
                code = Optional[String](_extract_string(b, coding_fields[0].value()))
            if coding_fields[1]:
                code_display = Optional[String](_extract_string(b, coding_fields[1].value()))

    var clinical_status = Optional[String](None)
    if top[3]:
        var cs_coding_start = _find_key(b, top[3].value(), "coding")
        if cs_coding_start:
            var cs0_start = _first_array_element(b, cs_coding_start.value())
            if cs0_start:
                var cs_code_field = _find_key(b, cs0_start.value(), "code")
                if cs_code_field:
                    clinical_status = Optional[String](_extract_string(b, cs_code_field.value()))

    var onset_datetime = Optional[String](None)
    if top[4]:
        onset_datetime = Optional[String](_extract_string(b, top[4].value()))

    var recorded_date = Optional[String](None)
    if top[5]:
        recorded_date = Optional[String](_extract_string(b, top[5].value()))

    return ConditionRow(
        id,
        patient_ref,
        code,
        code_display,
        clinical_status,
        onset_datetime,
        recorded_date,
    )
