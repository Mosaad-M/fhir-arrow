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
# calls to these two, matching resources.mojo's field list exactly — no
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


# ── _skip_string: i must point exactly at the opening quote ─────────────────


def _skip_string(b: Span[UInt8, _], start: Int) raises -> Int:
    var i = start + 1  # skip opening quote
    var n = len(b)
    while i < n:
        var c = b[i]
        if c == _BACKSLASH:
            i += 1
            if i >= n:
                raise Error("fast_shred: _skip_string: unterminated escape")
            if b[i] == _LOWER_U:
                i += 5  # 'u' + 4 hex digits
            else:
                i += 1
        elif c == _QUOTE:
            return i + 1
        else:
            i += 1
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
            var d = b[i]
            if d == _QUOTE:
                i = _skip_string(b, i)
            elif d == open_:
                depth += 1
                i += 1
            elif d == close:
                depth -= 1
                i += 1
            else:
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
