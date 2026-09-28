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
# SIMD_WIDTH = 16 (128-bit / 8-bit lanes), not 32: measured directly, not
# assumed. A width-32 chunk on this early-exit design needs two 128-bit
# vector ops plus a cross-register reduction to search one logical chunk,
# which is strictly more work than a single native-width op for the common
# case here (a hit found within the first register's worth of bytes, since
# most FHIR field values and skip-distances are shorter than either width).
# Measured with a standalone cross-language benchmark (same algorithm, same
# realistic 5-40 byte gap distribution as real FHIR field values) before
# changing this: width=16 is ~40% faster than width=32 for this exact
# access pattern, consistently across repeated runs. 16 bytes (128-bit) is
# also the *more* portable choice, not less: it's baseline SSE2 on every
# x86_64 CPU (not just AVX2-capable ones), and the native NEON register
# width on arm64 -- safe for this repo's declared linux-64/osx-arm64
# platforms without the AVX2-specific caveat the old width=32 comment had.

comptime _SIMD_WIDTH = 16


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
    (no escapes means byte count == char count), so the result is built
    with a single bulk `List.extend()` of the source slice (confirmed
    `List[UInt8].extend()` accepts a `Span[UInt8]` slice directly, no
    intermediate `List` conversion needed) instead of growing via
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
            result.extend(b[start + 1 : j])
            return String(unsafe_from_utf8=result^)
        elif c == _BACKSLASH:
            break
        j += 1
    return _extract_string_escaped(b, start)


def _decode_escaped_string_into(
    b: Span[UInt8, _], start: Int, mut out: List[UInt8]
) raises -> Int:
    """Core of the escape-decoding fallback: appends decoded bytes directly
    into the caller-supplied `out` buffer (extended, not replaced), so a
    streaming column builder can decode straight into its own value buffer
    without an intermediate String. Returns the index just past the closing
    quote. start must point at the opening quote. Same escape table as
    before this was factored out -- behavior-preserving, not a decode-logic
    change."""
    var n = len(b)
    var i = start + 1
    while i < n:
        var c = b[i]
        if c == _QUOTE:
            return i + 1
        elif c == _BACKSLASH:
            i += 1
            if i >= n:
                raise Error("fast_shred: _extract_string: unterminated escape")
            var esc = b[i]
            if esc == _QUOTE:
                out.append(_QUOTE)
            elif esc == _BACKSLASH:
                out.append(_BACKSLASH)
            elif esc == UInt8(ord("/")):
                out.append(UInt8(ord("/")))
            elif esc == UInt8(ord("n")):
                out.append(_LF)
            elif esc == UInt8(ord("r")):
                out.append(_CR)
            elif esc == UInt8(ord("t")):
                out.append(_TAB)
            elif esc == UInt8(ord("b")):
                out.append(UInt8(8))
            elif esc == UInt8(ord("f")):
                out.append(UInt8(12))
            elif esc == _LOWER_U:
                i += 4  # skip 4 hex digits (i itself advances past 'u' below)
                out.append(UInt8(ord("?")))
            else:
                out.append(esc)
            i += 1
        else:
            out.append(c)
            i += 1
    raise Error("fast_shred: _extract_string: unterminated string starting at " + String(start))


def _extract_string_escaped(b: Span[UInt8, _], start: Int) raises -> String:
    """Byte-by-byte escape-decoding fallback for _extract_string, used once
    a backslash has been seen. start must point at the opening quote."""
    var result = List[UInt8](capacity=32)
    _ = _decode_escaped_string_into(b, start, result)
    return String(unsafe_from_utf8=result^)


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
