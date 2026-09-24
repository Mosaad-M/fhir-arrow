# test_fast_shred.mojo: tests for the zero-tree byte-scanning FHIR shredder.
#
# Section 1: the two shared primitives (_skip_value, _find_key), tested
#            directly since they're the highest-risk hand-written code here.
# Section 2: shred_*_fast parity with test_resources.mojo's original cases.
# Section 3: adversarial cases the tree parser never had to worry about.

from fast_shred import _skip_value, _find_key


def assert_true(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


def assert_eq_int(a: Int, b: Int, msg: String) raises:
    if a != b:
        raise Error(
            "FAIL: " + msg + ", got " + String(a) + ", expected " + String(b)
        )


# ── _skip_value ────────────────────────────────────────────────────────────


def test_skip_value_simple_string() raises:
    var s = String('"hello", "next"')
    var b = s.as_bytes()
    var end = _skip_value(b, 0)
    assert_eq_int(end, 7, "should stop right after closing quote")


def test_skip_value_string_with_escaped_quote() raises:
    # "a\"b" — the \" must not be mistaken for the closing quote.
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


def main() raises:
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

    print("\nAll fast_shred primitive tests passed.")
