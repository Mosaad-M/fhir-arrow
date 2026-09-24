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
    """start must point at the opening quote."""
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


# ── Shared: first coding[0] of obj.code (mirrors resources.mojo's _coding0) ──


def _coding0_fast(b: Span[UInt8, _], obj_start: Int) raises -> Optional[Int]:
    var code_start = _find_key(b, obj_start, "code")
    if not code_start:
        return Optional[Int](None)
    var coding_start = _find_key(b, code_start.value(), "coding")
    if not coding_start:
        return Optional[Int](None)
    return _first_array_element(b, coding_start.value())


# ── Patient ──────────────────────────────────────────────────────────────────


def shred_patient_fast(line: String) raises -> PatientRow:
    """Zero-tree equivalent of resources.mojo's shred_patient: same v0
    field scope, same behavior on missing/optional fields."""
    var b = line.as_bytes()

    var id_start = _find_key(b, 0, "id")
    if not id_start:
        raise Error("fast_shred: shred_patient_fast: missing required field 'id'")
    var id = _extract_string(b, id_start.value())

    var gender = Optional[String](None)
    var gender_start = _find_key(b, 0, "gender")
    if gender_start:
        gender = Optional[String](_extract_string(b, gender_start.value()))

    var birth_date = Optional[String](None)
    var birth_date_start = _find_key(b, 0, "birthDate")
    if birth_date_start:
        birth_date = Optional[String](_extract_string(b, birth_date_start.value()))

    var family_name = Optional[String](None)
    var given_name = Optional[String](None)
    var name_start = _find_key(b, 0, "name")
    if name_start:
        var name0_start = _first_array_element(b, name_start.value())
        if name0_start:
            var family_start = _find_key(b, name0_start.value(), "family")
            if family_start:
                family_name = Optional[String](_extract_string(b, family_start.value()))
            var given_arr_start = _find_key(b, name0_start.value(), "given")
            if given_arr_start:
                var given0_start = _first_array_element(b, given_arr_start.value())
                if given0_start:
                    given_name = Optional[String](_extract_string(b, given0_start.value()))

    var deceased = Optional[Bool](None)
    var deceased_start = _find_key(b, 0, "deceasedBoolean")
    if deceased_start:
        deceased = Optional[Bool](_extract_bool(b, deceased_start.value()))

    return PatientRow(id, gender, birth_date, family_name, given_name, deceased)


# ── Observation ──────────────────────────────────────────────────────────────


def shred_observation_fast(line: String) raises -> ObservationRow:
    """Zero-tree equivalent of resources.mojo's shred_observation."""
    var b = line.as_bytes()

    var id_start = _find_key(b, 0, "id")
    if not id_start:
        raise Error("fast_shred: shred_observation_fast: missing required field 'id'")
    var id = _extract_string(b, id_start.value())

    var patient_ref = Optional[String](None)
    var subject_start = _find_key(b, 0, "subject")
    if subject_start:
        var ref_start = _find_key(b, subject_start.value(), "reference")
        if ref_start:
            patient_ref = Optional[String](_extract_string(b, ref_start.value()))

    var code = Optional[String](None)
    var code_system = Optional[String](None)
    var code_display = Optional[String](None)
    var coding0_start = _coding0_fast(b, 0)
    if coding0_start:
        var c0 = coding0_start.value()
        var code_field = _find_key(b, c0, "code")
        if code_field:
            code = Optional[String](_extract_string(b, code_field.value()))
        var system_field = _find_key(b, c0, "system")
        if system_field:
            code_system = Optional[String](_extract_string(b, system_field.value()))
        var display_field = _find_key(b, c0, "display")
        if display_field:
            code_display = Optional[String](_extract_string(b, display_field.value()))

    var status = Optional[String](None)
    var status_start = _find_key(b, 0, "status")
    if status_start:
        status = Optional[String](_extract_string(b, status_start.value()))

    var effective_datetime = Optional[String](None)
    var eff_start = _find_key(b, 0, "effectiveDateTime")
    if eff_start:
        effective_datetime = Optional[String](_extract_string(b, eff_start.value()))

    var value_quantity = Optional[Float64](None)
    var value_unit = Optional[String](None)
    var value_string = Optional[String](None)
    var vq_start = _find_key(b, 0, "valueQuantity")
    if vq_start:
        var vq = vq_start.value()
        var val_field = _find_key(b, vq, "value")
        if val_field:
            value_quantity = Optional[Float64](_extract_number(b, val_field.value()))
        var unit_field = _find_key(b, vq, "unit")
        if unit_field:
            value_unit = Optional[String](_extract_string(b, unit_field.value()))
    else:
        var vs_start = _find_key(b, 0, "valueString")
        if vs_start:
            value_string = Optional[String](_extract_string(b, vs_start.value()))

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


def shred_condition_fast(line: String) raises -> ConditionRow:
    """Zero-tree equivalent of resources.mojo's shred_condition."""
    var b = line.as_bytes()

    var id_start = _find_key(b, 0, "id")
    if not id_start:
        raise Error("fast_shred: shred_condition_fast: missing required field 'id'")
    var id = _extract_string(b, id_start.value())

    var patient_ref = Optional[String](None)
    var subject_start = _find_key(b, 0, "subject")
    if subject_start:
        var ref_start = _find_key(b, subject_start.value(), "reference")
        if ref_start:
            patient_ref = Optional[String](_extract_string(b, ref_start.value()))

    var code = Optional[String](None)
    var code_display = Optional[String](None)
    var coding0_start = _coding0_fast(b, 0)
    if coding0_start:
        var c0 = coding0_start.value()
        var code_field = _find_key(b, c0, "code")
        if code_field:
            code = Optional[String](_extract_string(b, code_field.value()))
        var display_field = _find_key(b, c0, "display")
        if display_field:
            code_display = Optional[String](_extract_string(b, display_field.value()))

    var clinical_status = Optional[String](None)
    var cs_start = _find_key(b, 0, "clinicalStatus")
    if cs_start:
        var cs_coding_start = _find_key(b, cs_start.value(), "coding")
        if cs_coding_start:
            var cs0_start = _first_array_element(b, cs_coding_start.value())
            if cs0_start:
                var cs_code_field = _find_key(b, cs0_start.value(), "code")
                if cs_code_field:
                    clinical_status = Optional[String](_extract_string(b, cs_code_field.value()))

    var onset_datetime = Optional[String](None)
    var onset_start = _find_key(b, 0, "onsetDateTime")
    if onset_start:
        onset_datetime = Optional[String](_extract_string(b, onset_start.value()))

    var recorded_date = Optional[String](None)
    var recorded_start = _find_key(b, 0, "recordedDate")
    if recorded_start:
        recorded_date = Optional[String](_extract_string(b, recorded_start.value()))

    return ConditionRow(
        id,
        patient_ref,
        code,
        code_display,
        clinical_status,
        onset_datetime,
        recorded_date,
    )
