# test_fast_shred.mojo: tests for the zero-tree byte-scanning FHIR shredder.
#
# Section 1: the two shared primitives (_skip_value, _find_key), tested
#            directly since they're the highest-risk hand-written code here.
# Section 2: shred_*_fast parity with test_resources.mojo's original cases.
# Section 3: adversarial cases the tree parser never had to worry about.

from fast_shred import (
    _skip_value, _find_key, _first_array_element,
    shred_patient_fast, shred_observation_fast, shred_condition_fast,
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


# ── Section 2: shred_*_fast parity with test_resources.mojo ──────────────────
# Same fixtures, same expected values, calling *_fast instead of the
# json.mojo-tree-based originals.


def test_shred_patient_fast_minimal() raises:
    var line = String(
        '{"resourceType": "Patient", "id": "p1", "gender": "female",'
        ' "birthDate": "1990-01-01"}'
    )
    var row = shred_patient_fast(line)
    assert_eq_str(row.id, "p1", "id")
    assert_true(row.gender.value() == "female", "gender")
    assert_true(row.birth_date.value() == "1990-01-01", "birth_date")
    assert_true(not row.family_name, "family_name should be null")
    assert_true(not row.given_name, "given_name should be null")
    assert_true(not row.deceased, "deceased should be null")


def test_shred_patient_fast_with_name() raises:
    var line = String(
        '{"id": "p2", "name": [{"family": "Smith", "given": ["Jane", "Q"]}]}'
    )
    var row = shred_patient_fast(line)
    assert_true(row.family_name.value() == "Smith", "family_name")
    assert_true(row.given_name.value() == "Jane", "given_name (first only)")


def test_shred_patient_fast_deceased_boolean() raises:
    var line = String('{"id": "p3", "deceasedBoolean": true}')
    var row = shred_patient_fast(line)
    assert_true(row.deceased.value() == True, "deceased true")


def test_shred_patient_fast_missing_id_raises() raises:
    var line = String('{"gender": "male"}')
    var raised = False
    try:
        _ = shred_patient_fast(line)
    except:
        raised = True
    assert_true(raised, "missing id should raise")


def test_shred_observation_fast_value_quantity() raises:
    var line = String(
        '{"id": "o1", "status": "final",'
        ' "subject": {"reference": "Patient/p1"},'
        ' "code": {"coding": [{"system": "http://loinc.org", "code": "4548-4",'
        ' "display": "Hemoglobin A1c"}]},'
        ' "effectiveDateTime": "2024-01-01T00:00:00Z",'
        ' "valueQuantity": {"value": 5.4, "unit": "%"}}'
    )
    var row = shred_observation_fast(line)
    assert_eq_str(row.id, "o1", "id")
    assert_eq_str(row.patient_ref.value(), "Patient/p1", "patient_ref")
    assert_eq_str(row.code.value(), "4548-4", "code")
    assert_eq_str(row.code_system.value(), "http://loinc.org", "code_system")
    assert_eq_str(row.code_display.value(), "Hemoglobin A1c", "code_display")
    assert_eq_str(row.status.value(), "final", "status")
    assert_eq_str(
        row.effective_datetime.value(),
        "2024-01-01T00:00:00Z",
        "effective_datetime",
    )
    assert_near(row.value_quantity.value(), 5.4, "value_quantity")
    assert_eq_str(row.value_unit.value(), "%", "value_unit")
    assert_true(not row.value_string, "value_string should be null")


def test_shred_observation_fast_value_string() raises:
    var line = String(
        '{"id": "o2", "code": {"coding": [{"code": "obs-note"}]},'
        ' "valueString": "no acute findings"}'
    )
    var row = shred_observation_fast(line)
    assert_eq_str(row.value_string.value(), "no acute findings", "value_string")
    assert_true(not row.value_quantity, "value_quantity should be null")
    assert_true(not row.value_unit, "value_unit should be null")


def test_shred_observation_fast_no_value() raises:
    var line = String('{"id": "o3", "code": {"coding": [{"code": "x"}]}}')
    var row = shred_observation_fast(line)
    assert_true(not row.value_quantity, "value_quantity should be null")
    assert_true(not row.value_string, "value_string should be null")


def test_shred_observation_fast_missing_id_raises() raises:
    var line = String('{"status": "final"}')
    var raised = False
    try:
        _ = shred_observation_fast(line)
    except:
        raised = True
    assert_true(raised, "missing id should raise")


def test_shred_condition_fast_full() raises:
    var line = String(
        '{"id": "c1", "subject": {"reference": "Patient/p1"},'
        ' "code": {"coding": [{"code": "44054006", "display": "Diabetes"}]},'
        ' "clinicalStatus": {"coding": [{"code": "active"}]},'
        ' "onsetDateTime": "2020-05-01",'
        ' "recordedDate": "2020-05-02"}'
    )
    var row = shred_condition_fast(line)
    assert_eq_str(row.id, "c1", "id")
    assert_eq_str(row.patient_ref.value(), "Patient/p1", "patient_ref")
    assert_eq_str(row.code.value(), "44054006", "code")
    assert_eq_str(row.code_display.value(), "Diabetes", "code_display")
    assert_eq_str(row.clinical_status.value(), "active", "clinical_status")
    assert_eq_str(row.onset_datetime.value(), "2020-05-01", "onset_datetime")
    assert_eq_str(row.recorded_date.value(), "2020-05-02", "recorded_date")


def test_shred_condition_fast_no_onset() raises:
    var line = String('{"id": "c2", "code": {"coding": [{"code": "x"}]}}')
    var row = shred_condition_fast(line)
    assert_true(not row.onset_datetime, "onset_datetime should be null")


def test_shred_condition_fast_missing_id_raises() raises:
    var line = String('{"code": {"coding": [{"code": "x"}]}}')
    var raised = False
    try:
        _ = shred_condition_fast(line)
    except:
        raised = True
    assert_true(raised, "missing id should raise")


# ── Section 3: shredder-level adversarial cases ───────────────────────────────
# The tree parser never had to worry about these; a hand-rolled scanner must.


def test_shred_observation_fast_note_with_escaped_structural_chars() raises:
    """A 'note' field (not in our schema, so it's skipped) containing
    escaped quotes/braces/brackets must not corrupt extraction of the
    real fields that come after it."""
    var line = String(
        '{"id": "o4", "note": "patient said \\"ok\\", {no code} [fine]",'
        ' "status": "final", "code": {"coding": [{"code": "9279-1"}]}}'
    )
    var row = shred_observation_fast(line)
    assert_eq_str(row.id, "o4", "id")
    assert_eq_str(row.status.value(), "final", "status survives the adversarial note field")
    assert_eq_str(row.code.value(), "9279-1", "code survives the adversarial note field")


def test_shred_observation_fast_code_key_collision() raises:
    """'code' exists as a top-level CodeableConcept object AND as a key
    inside coding[0]. Must extract the nested coding[0].code ('4548-4'),
    not be confused by the top-level 'code' object itself."""
    var line = String(
        '{"id": "o5", "code": {"coding": [{"system": "http://loinc.org",'
        ' "code": "4548-4", "display": "Hemoglobin A1c"}]}}'
    )
    var row = shred_observation_fast(line)
    assert_eq_str(row.code.value(), "4548-4", "should read coding[0].code, not confuse the outer object")


def test_shred_observation_fast_out_of_order_with_unknown_fields() raises:
    """Real Synthea output won't match hand-written fixture key ordering,
    and carries many fields (meta, text, category, encounter, performer)
    this v0 doesn't care about, interspersed among the fields it does."""
    var line = String(
        '{"resourceType": "Observation",'
        ' "meta": {"versionId": "1", "lastUpdated": "2024-01-01T00:00:00Z"},'
        ' "status": "final",'
        ' "category": [{"coding": [{"system": "http://x", "code": "vital-signs"}]}],'
        ' "code": {"coding": [{"system": "http://loinc.org", "code": "8302-2",'
        ' "display": "Body Height"}]},'
        ' "subject": {"reference": "Patient/p1"},'
        ' "encounter": {"reference": "Encounter/e1"},'
        ' "effectiveDateTime": "2024-01-01T00:00:00Z",'
        ' "valueQuantity": {"value": 170.0, "unit": "cm", "system": "http://unitsofmeasure.org"},'
        ' "id": "o6"}'
    )
    var row = shred_observation_fast(line)
    assert_eq_str(row.id, "o6", "id found despite appearing last")
    assert_eq_str(row.code.value(), "8302-2", "code found past the unrelated category coding array")
    assert_eq_str(row.patient_ref.value(), "Patient/p1", "patient_ref")
    assert_near(row.value_quantity.value(), 170.0, "value_quantity")
    assert_eq_str(row.value_unit.value(), "cm", "value_unit (not confused by valueQuantity.system)")


def test_shred_observation_fast_multiple_coding_entries() raises:
    """Only coding[0] should be read when multiple entries are present."""
    var line = String(
        '{"id": "o7", "code": {"coding": ['
        '{"system": "http://loinc.org", "code": "FIRST", "display": "First Code"},'
        '{"system": "http://snomed.info/sct", "code": "SECOND", "display": "Second Code"}'
        ']}}'
    )
    var row = shred_observation_fast(line)
    assert_eq_str(row.code.value(), "FIRST", "only the first coding entry should be read")
    assert_eq_str(row.code_display.value(), "First Code", "only the first coding entry should be read")


def test_shred_condition_fast_unicode_escape_in_skipped_field() raises:
    """A unicode escape inside a skipped field (not in our schema) must
    not desynchronize byte offsets for the fields that follow it."""
    var line = String(
        '{"id": "c3", "note": "caf\\u00e9 follow-up",'
        ' "code": {"coding": [{"code": "44054006", "display": "Diabetes"}]},'
        ' "onsetDateTime": "2020-05-01"}'
    )
    var row = shred_condition_fast(line)
    assert_eq_str(row.id, "c3", "id")
    assert_eq_str(row.code.value(), "44054006", "code survives the unicode escape in note")
    assert_eq_str(row.onset_datetime.value(), "2020-05-01", "onset_datetime survives the unicode escape in note")


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

    test_first_array_element_present()
    print("PASS test_first_array_element_present")
    test_first_array_element_empty_array()
    print("PASS test_first_array_element_empty_array")
    test_first_array_element_of_objects()
    print("PASS test_first_array_element_of_objects")
    test_first_array_element_skips_leading_whitespace()
    print("PASS test_first_array_element_skips_leading_whitespace")

    test_shred_patient_fast_minimal()
    print("PASS test_shred_patient_fast_minimal")
    test_shred_patient_fast_with_name()
    print("PASS test_shred_patient_fast_with_name")
    test_shred_patient_fast_deceased_boolean()
    print("PASS test_shred_patient_fast_deceased_boolean")
    test_shred_patient_fast_missing_id_raises()
    print("PASS test_shred_patient_fast_missing_id_raises")

    test_shred_observation_fast_value_quantity()
    print("PASS test_shred_observation_fast_value_quantity")
    test_shred_observation_fast_value_string()
    print("PASS test_shred_observation_fast_value_string")
    test_shred_observation_fast_no_value()
    print("PASS test_shred_observation_fast_no_value")
    test_shred_observation_fast_missing_id_raises()
    print("PASS test_shred_observation_fast_missing_id_raises")

    test_shred_condition_fast_full()
    print("PASS test_shred_condition_fast_full")
    test_shred_condition_fast_no_onset()
    print("PASS test_shred_condition_fast_no_onset")
    test_shred_condition_fast_missing_id_raises()
    print("PASS test_shred_condition_fast_missing_id_raises")

    test_shred_observation_fast_note_with_escaped_structural_chars()
    print("PASS test_shred_observation_fast_note_with_escaped_structural_chars")
    test_shred_observation_fast_code_key_collision()
    print("PASS test_shred_observation_fast_code_key_collision")
    test_shred_observation_fast_out_of_order_with_unknown_fields()
    print("PASS test_shred_observation_fast_out_of_order_with_unknown_fields")
    test_shred_observation_fast_multiple_coding_entries()
    print("PASS test_shred_observation_fast_multiple_coding_entries")
    test_shred_condition_fast_unicode_escape_in_skipped_field()
    print("PASS test_shred_condition_fast_unicode_escape_in_skipped_field")

    print("\nAll fast_shred tests passed.")
