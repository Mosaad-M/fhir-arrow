# test_fast_shred.mojo: tests for the zero-tree byte-scanning FHIR shredder.
#
# Section 1: the two shared primitives (_skip_value, _find_key), tested
#            directly since they're the highest-risk hand-written code here.
# Section 2: shred_*_fast parity with test_resources.mojo's original cases.
# Section 3: adversarial cases the tree parser never had to worry about.

from fast_shred import (
    _skip_value, _skip_string, _find_key, _find_keys, _first_array_element, _extract_string,
    _simd_find_first2, _simd_find_first3, _SIMD_WIDTH,
)


def assert_true(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


def assert_eq_int(a: Int, b: Int, msg: String) raises:
    if a != b:
        raise Error(
            "FAIL: " + msg + ", got " + String(a) + ", expected " + String(b)
        )


def assert_eq_str(a: String, b: String, msg: String) raises:
    if a != b:
        raise Error("FAIL: " + msg + ", got '" + a + "', expected '" + b + "'")


def assert_near(a: Float64, b: Float64, msg: String) raises:
    var diff = a - b
    if diff < 0:
        diff = -diff
    if diff > 1e-9:
        raise Error(
            "FAIL: " + msg + ", got " + String(a) + ", expected " + String(b)
        )


# ── _simd_find_first2 / _simd_find_first3 ────────────────────────────────────
# Boundary-focused: this is where a chunked SIMD search could actually have
# bugs even under the "safe" design (only accelerating candidate-finding,
# never changing decision logic) — off-by-one at chunk edges, not
# escape/depth logic, which is unchanged and already covered below. (An
# earlier batch-extraction version of this section, and its multi-hit
# tests, was tried and reverted after measuring a real regression — see
# fast_shred.mojo's header comment and tasks/lessons.md.)


def _padded(prefix_len: Int, target: String, suffix_len: Int) -> String:
    """Build "a"*prefix_len + target + "a"*suffix_len, for placing a target
    byte at an exact offset relative to a scan start."""
    var s = String()
    for _ in range(prefix_len):
        s += "a"
    s += target
    for _ in range(suffix_len):
        s += "a"
    return s


def test_simd_find_first3_candidate_at_width_plus_2() raises:
    var s = _padded(_SIMD_WIDTH + 2, "Z", 5)
    var b = s.as_bytes()
    var pos = _simd_find_first3(b, 0, UInt8(ord("X")), UInt8(ord("Y")), UInt8(ord("Z")))
    assert_eq_int(pos, _SIMD_WIDTH + 2, "third target byte should be found across the chunk boundary")


def test_simd_find_first2_candidate_at_width_minus_1() raises:
    var s = _padded(_SIMD_WIDTH - 1, "X", 10)
    var b = s.as_bytes()
    var pos = _simd_find_first2(b, 0, UInt8(ord("X")), UInt8(ord("Y")))
    assert_eq_int(pos, _SIMD_WIDTH - 1, "candidate at W-1 should be found inside the first chunk")


def test_simd_find_first2_span_shorter_than_width() raises:
    var s = String("aaXaaa")
    var b = s.as_bytes()
    var pos = _simd_find_first2(b, 0, UInt8(ord("X")), UInt8(ord("Y")))
    assert_eq_int(pos, 2, "short span should still be scanned correctly via the scalar tail")


def test_simd_find_first2_not_found_returns_length() raises:
    var s = _padded(_SIMD_WIDTH + 10, "", 0)
    var b = s.as_bytes()
    var pos = _simd_find_first2(b, 0, UInt8(ord("X")), UInt8(ord("Y")))
    assert_eq_int(pos, len(b), "no match should return len(b)")


# ── Escaped-quote adjacency ───────────────────────────────────────────────
# Extra adversarial coverage for _skip_string's escape handling when
# multiple escape sequences / quotes sit close together, the kind of dense
# packing real FHIR "note"-style free-text fields can have.


def test_skip_string_escaped_quote_immediately_followed_by_real_quote() raises:
    # `\"X"` -- an escaped quote immediately followed by the real closing
    # quote. The escaped quote must not be
    # mistaken for the terminator.
    var s = String('"\\"X"')  # opening quote, \", X, closing quote
    var b = s.as_bytes()
    var end = _skip_string(b, 0)
    assert_eq_int(end, len(b), "must consume through the real closing quote, not the escaped one")


def test_skip_string_multiple_escaped_quotes_then_real_quote() raises:
    var s = String('"\\"\\"\\"done"')  # three escaped quotes, then "done", then real close
    var b = s.as_bytes()
    var end = _skip_string(b, 0)
    assert_eq_int(end, len(b), "must skip all three escaped quotes and stop at the real one")


def test_skip_string_unicode_escape_consuming_past_a_pending_hit() raises:
    # " is a literal backslash-u-0022 sequence (not an actual quote
    # byte) -- the extractor still only sees a backslash as the hit; the
    # hex digits that follow are never targets, so this mainly proves the
    # +5 consumption doesn't desync the cursor from subsequent real hits.
    var s = String('"a\\u0022b\\"c"')  # a, " (escape), b, \" (escape), c, real close
    var b = s.as_bytes()
    var end = _skip_string(b, 0)
    assert_eq_int(end, len(b), "unicode escape followed by another escape then the real terminator")


def test_skip_value_object_with_many_short_adjacent_string_fields() raises:
    # Mirrors real FHIR shape (dense, many short key/value pairs close
    # together, like Observation's `category`/`meta`) -- multiple quote
    # hits packed within a single chunk, well under _SIMD_WIDTH apart.
    var s = String('{"a":"1","b":"2","c":"3","d":"4","e":"5"}')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, len(b), "dense object with many close-together hits must still skip correctly")


# ── _skip_value ────────────────────────────────────────────────────────────


def test_skip_value_simple_string() raises:
    var s = String('"hello", "next"')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 7, "should stop right after closing quote")


def test_skip_value_string_with_escaped_quote() raises:
    # "a\"b": the \" must not be mistaken for the closing quote.
    var s = String('"a\\"b", "next"')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 6, "should skip past the real closing quote, not the escaped one")


def test_skip_value_number() raises:
    var s = String("123.45, 6")
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 6, "should stop at the comma")


def test_skip_value_true_false_null() raises:
    var s1 = String("true, 1")
    var end1 = _skip_value(s1.as_bytes(), 0)
    assert_eq_int(end1, 4, "true")

    var s2 = String("false, 1")
    var end2 = _skip_value(s2.as_bytes(), 0)
    assert_eq_int(end2, 5, "false")

    var s3 = String("null, 1")
    var end3 = _skip_value(s3.as_bytes(), 0)
    assert_eq_int(end3, 4, "null")


def test_skip_value_nested_object() raises:
    var s = String('{"a": {"b": 1}, "c": 2}, "next"')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 23, "should skip the whole nested object")


def test_skip_value_nested_array_with_objects() raises:
    var s = String('[1, [2, 3], {"a": [4, 5]}], "next"')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 26, "should skip the whole nested array")


def test_skip_value_string_containing_structural_chars() raises:
    # A string value containing braces/brackets must not perturb depth
    # counting for whatever comes after it.
    var s = String('"patient said {no code} and [nothing]", "next"')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 38, "should skip the whole string, ignoring braces/brackets inside it")


def test_skip_value_object_containing_string_with_braces() raises:
    var s = String('{"note": "a {fake} brace", "code": "44"}, "next"')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 40, "braces inside the note string must not affect object depth counting")


def test_skip_value_string_with_unicode_escape() raises:
    var s = String('"caf\\u00e9 note", "next"')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 16, "should skip past the \\u escape without miscounting bytes")


# ── _find_key ────────────────────────────────────────────────────────────────


def test_find_key_found_first() raises:
    var s = String('{"id": "p1", "gender": "female"}')
    var b = s.as_bytes()
    var start = _find_key(b, 0, "id")
    assert_true(Bool(start), "id should be found")
    assert_eq_int(start.value(), 7, "value_start should point at the opening quote of \"p1\"")


def test_find_key_found_last() raises:
    var s = String('{"id": "p1", "gender": "female"}')
    var b = s.as_bytes()
    var start = _find_key(b, 0, "gender")
    assert_true(Bool(start), "gender should be found")
    assert_eq_int(start.value(), 23, "value_start should point at the opening quote of \"female\"")


def test_find_key_not_found() raises:
    var s = String('{"id": "p1", "gender": "female"}')
    var b = s.as_bytes()
    var start = _find_key(b, 0, "birthDate")
    assert_true(not Bool(start), "birthDate should not be found")


def test_find_key_does_not_prefix_match() raises:
    # Searching for "code" must not match a "coding" key.
    var s = String('{"coding": "x", "code": "y"}')
    var b = s.as_bytes()
    var start = _find_key(b, 0, "code")
    assert_true(Bool(start), "code should be found")
    assert_eq_int(start.value(), 24, "should match the real \"code\" key, not \"coding\"")


def test_find_key_only_direct_keys_not_nested() raises:
    # "code" exists both as a top-level object AND as a nested key inside
    # coding[0]. _find_key on the outer object must return the top-level
    # one (the object start), not reach into the nested array.
    var s = String(
        '{"code": {"coding": [{"code": "4548-4", "system": "http://loinc.org"}]}}'
    )
    var b = s.as_bytes()
    var start = _find_key(b, 0, "code")
    assert_true(Bool(start), "top-level code should be found")
    # value_start should point at the '{' of the CodeableConcept object, not
    # at "4548-4" inside the nested coding array.
    assert_true(b[start.value()] == UInt8(ord("{")), "should point at the nested object's opening brace")


def test_find_key_out_of_order_with_unknown_fields() raises:
    # Real Synthea output won't match hand-written fixture key ordering,
    # and has many fields we don't care about interspersed.
    var s = String(
        '{"resourceType": "Patient", "meta": {"x": 1}, "gender": "male",'
        ' "text": {"status": "generated"}, "id": "p9", "extension": []}'
    )
    var b = s.as_bytes()
    var id_start = _find_key(b, 0, "id")
    assert_true(Bool(id_start), "id should be found despite appearing late and out of order")
    var gender_start = _find_key(b, 0, "gender")
    assert_true(Bool(gender_start), "gender should be found despite unrelated nested objects around it")


# ── _find_keys ───────────────────────────────────────────────────────────────


def test_find_keys_all_present_same_order() raises:
    var s = String('{"id": "p1", "gender": "female", "birthDate": "1990-01-01"}')
    var b = s.as_bytes()
    var keys: List[String] = ["id", "gender", "birthDate"]
    var starts = _find_keys(b, 0, keys)
    assert_eq_int(len(starts), 3, "should return one slot per requested key")
    assert_true(Bool(starts[0]), "id should be found")
    assert_true(Bool(starts[1]), "gender should be found")
    assert_true(Bool(starts[2]), "birthDate should be found")
    # Cross-check against single-key _find_key for the exact same indices.
    assert_eq_int(starts[0].value(), _find_key(b, 0, "id").value(), "id index should match _find_key")
    assert_eq_int(starts[1].value(), _find_key(b, 0, "gender").value(), "gender index should match _find_key")
    assert_eq_int(starts[2].value(), _find_key(b, 0, "birthDate").value(), "birthDate index should match _find_key")


def test_find_keys_all_present_different_order() raises:
    # Object key order does not match the requested key order.
    var s = String('{"birthDate": "1990-01-01", "id": "p1", "gender": "female"}')
    var b = s.as_bytes()
    var keys: List[String] = ["id", "gender", "birthDate"]
    var starts = _find_keys(b, 0, keys)
    assert_eq_int(starts[0].value(), _find_key(b, 0, "id").value(), "id index should match _find_key regardless of scan order")
    assert_eq_int(starts[1].value(), _find_key(b, 0, "gender").value(), "gender index should match _find_key regardless of scan order")
    assert_eq_int(starts[2].value(), _find_key(b, 0, "birthDate").value(), "birthDate index should match _find_key regardless of scan order")


def test_find_keys_some_absent() raises:
    var s = String('{"id": "p1", "gender": "female"}')
    var b = s.as_bytes()
    var keys: List[String] = ["id", "gender", "birthDate", "deceasedBoolean"]
    var starts = _find_keys(b, 0, keys)
    assert_true(Bool(starts[0]), "id should be found")
    assert_true(Bool(starts[1]), "gender should be found")
    assert_true(not Bool(starts[2]), "birthDate should be absent")
    assert_true(not Bool(starts[3]), "deceasedBoolean should be absent")


def test_find_keys_no_false_positive_on_prefix() raises:
    # Wanting "code" must not match "codePrefix" (or "coding").
    var s = String('{"codePrefix": "x", "coding": "y", "code": "z"}')
    var b = s.as_bytes()
    var keys: List[String] = ["code"]
    var starts = _find_keys(b, 0, keys)
    assert_true(Bool(starts[0]), "code should be found")
    assert_eq_int(starts[0].value(), _find_key(b, 0, "code").value(), "should match the real \"code\" key only")


def test_find_keys_all_found_early_does_not_overread() raises:
    # All wanted keys appear as the first two entries; a large unrelated
    # trailing object (including one that looks like it could desync
    # scanning, e.g. contains braces/brackets in a string) must not be
    # touched incorrectly and must not cause an out-of-bounds/parse error.
    var s = String(
        '{"id": "p1", "gender": "female", "note": "trailing {weird} [stuff]",'
        ' "extension": [{"url": "x", "valueString": "y"}], "meta": {"a": 1}}'
    )
    var b = s.as_bytes()
    var keys: List[String] = ["id", "gender"]
    var starts = _find_keys(b, 0, keys)
    assert_true(Bool(starts[0]), "id should be found")
    assert_true(Bool(starts[1]), "gender should be found")
    assert_eq_int(starts[0].value(), _find_key(b, 0, "id").value(), "id index should match _find_key")
    assert_eq_int(starts[1].value(), _find_key(b, 0, "gender").value(), "gender index should match _find_key")


# ── _first_array_element ──────────────────────────────────────────────────────


def test_first_array_element_present() raises:
    var s = String('[1, 2, 3]')
    var b = s.as_bytes()
    var start = _first_array_element(b, 0)
    assert_true(Bool(start), "should find a first element")
    assert_eq_int(start.value(), 1, "should point at the '1'")


def test_first_array_element_empty_array() raises:
    var s = String("[]")
    var b = s.as_bytes()
    var start = _first_array_element(b, 0)
    assert_true(not Bool(start), "empty array has no first element")


def test_first_array_element_of_objects() raises:
    var s = String('[{"code": "a"}, {"code": "b"}]')
    var b = s.as_bytes()
    var start = _first_array_element(b, 0)
    assert_true(Bool(start), "should find a first element")
    assert_true(b[start.value()] == UInt8(ord("{")), "should point at the first object's opening brace")


def test_first_array_element_skips_leading_whitespace() raises:
    var s = String('[ "x", "y"]')
    var b = s.as_bytes()
    var start = _first_array_element(b, 0)
    assert_true(Bool(start), "should find a first element")
    assert_true(b[start.value()] == UInt8(ord('"')), "should point at the opening quote, past the leading space")


# ── _extract_string: escape-free fast path (Phase B) ─────────────────────────
# Most FHIR field values (ids, LOINC codes, ISO dates) never contain an
# escape. These cases must all produce the exact same output as before the
# fast path was added — this is a performance-only change.


def test_extract_string_no_escape_fast_path() raises:
    var s = String('"hello world"')
    var b = s.as_bytes()
    var v = _extract_string(b, 0)
    assert_eq_str(v, "hello world", "no-escape string")


def test_extract_string_with_escape_falls_back() raises:
    var s = String('"a\\"quoted\\" word"')
    var b = s.as_bytes()
    var v = _extract_string(b, 0)
    assert_eq_str(v, 'a"quoted" word', "escaped-quote string, decoded")


def test_extract_string_empty() raises:
    var s = String('""')
    var b = s.as_bytes()
    var v = _extract_string(b, 0)
    assert_eq_str(v, "", "empty string")


def test_extract_string_entirely_escapes() raises:
    var s = String('"\\n\\t\\\\"')
    var b = s.as_bytes()
    var v = _extract_string(b, 0)
    assert_eq_str(v, "\n\t\\", "string that is entirely escape sequences")


def test_extract_string_no_escape_long() raises:
    """Long enough to exceed the old fixed capacity=32 buffer, to prove
    the fast path's bulk copy isn't just correct for short strings."""
    var s = String(
        '"' + "0123456789" * 5 + '"'
    )
    var b = s.as_bytes()
    var v = _extract_string(b, 0)
    assert_eq_str(v, "0123456789" * 5, "long no-escape string")

def main() raises:
    test_simd_find_first3_candidate_at_width_plus_2()
    print("PASS test_simd_find_first3_candidate_at_width_plus_2")

    test_simd_find_first2_candidate_at_width_minus_1()
    print("PASS test_simd_find_first2_candidate_at_width_minus_1")
    test_simd_find_first2_span_shorter_than_width()
    print("PASS test_simd_find_first2_span_shorter_than_width")
    test_simd_find_first2_not_found_returns_length()
    print("PASS test_simd_find_first2_not_found_returns_length")

    test_skip_string_escaped_quote_immediately_followed_by_real_quote()
    print("PASS test_skip_string_escaped_quote_immediately_followed_by_real_quote")
    test_skip_string_multiple_escaped_quotes_then_real_quote()
    print("PASS test_skip_string_multiple_escaped_quotes_then_real_quote")
    test_skip_string_unicode_escape_consuming_past_a_pending_hit()
    print("PASS test_skip_string_unicode_escape_consuming_past_a_pending_hit")
    test_skip_value_object_with_many_short_adjacent_string_fields()
    print("PASS test_skip_value_object_with_many_short_adjacent_string_fields")

    test_skip_value_simple_string()
    print("PASS test_skip_value_simple_string")
    test_skip_value_string_with_escaped_quote()
    print("PASS test_skip_value_string_with_escaped_quote")
    test_skip_value_number()
    print("PASS test_skip_value_number")
    test_skip_value_true_false_null()
    print("PASS test_skip_value_true_false_null")
    test_skip_value_nested_object()
    print("PASS test_skip_value_nested_object")
    test_skip_value_nested_array_with_objects()
    print("PASS test_skip_value_nested_array_with_objects")
    test_skip_value_string_containing_structural_chars()
    print("PASS test_skip_value_string_containing_structural_chars")
    test_skip_value_object_containing_string_with_braces()
    print("PASS test_skip_value_object_containing_string_with_braces")
    test_skip_value_string_with_unicode_escape()
    print("PASS test_skip_value_string_with_unicode_escape")

    test_find_key_found_first()
    print("PASS test_find_key_found_first")
    test_find_key_found_last()
    print("PASS test_find_key_found_last")
    test_find_key_not_found()
    print("PASS test_find_key_not_found")
    test_find_key_does_not_prefix_match()
    print("PASS test_find_key_does_not_prefix_match")
    test_find_key_only_direct_keys_not_nested()
    print("PASS test_find_key_only_direct_keys_not_nested")
    test_find_key_out_of_order_with_unknown_fields()
    print("PASS test_find_key_out_of_order_with_unknown_fields")

    test_find_keys_all_present_same_order()
    print("PASS test_find_keys_all_present_same_order")
    test_find_keys_all_present_different_order()
    print("PASS test_find_keys_all_present_different_order")
    test_find_keys_some_absent()
    print("PASS test_find_keys_some_absent")
    test_find_keys_no_false_positive_on_prefix()
    print("PASS test_find_keys_no_false_positive_on_prefix")
    test_find_keys_all_found_early_does_not_overread()
    print("PASS test_find_keys_all_found_early_does_not_overread")

    test_first_array_element_present()
    print("PASS test_first_array_element_present")
    test_first_array_element_empty_array()
    print("PASS test_first_array_element_empty_array")
    test_first_array_element_of_objects()
    print("PASS test_first_array_element_of_objects")
    test_first_array_element_skips_leading_whitespace()
    print("PASS test_first_array_element_skips_leading_whitespace")

    test_extract_string_no_escape_fast_path()
    print("PASS test_extract_string_no_escape_fast_path")
    test_extract_string_with_escape_falls_back()
    print("PASS test_extract_string_with_escape_falls_back")
    test_extract_string_empty()
    print("PASS test_extract_string_empty")
    test_extract_string_entirely_escapes()
    print("PASS test_extract_string_entirely_escapes")
    test_extract_string_no_escape_long()
    print("PASS test_extract_string_no_escape_long")

    print("\nAll fast_shred tests passed.")
