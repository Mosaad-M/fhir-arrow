from resources import PatientRow, shred_patient
from json import parse_json


def assert_true(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


def assert_eq_str(a: String, b: String, msg: String) raises:
    if a != b:
        raise Error("FAIL: " + msg + ", got '" + a + "', expected '" + b + "'")


# ── Patient ──────────────────────────────────────────────────────────────────


def test_shred_patient_minimal() raises:
    """Minimal Patient (id/gender/birthDate only) shreds with name/deceased null."""
    var obj = parse_json(
        '{"resourceType": "Patient", "id": "p1", "gender": "female",'
        ' "birthDate": "1990-01-01"}'
    )
    var row = shred_patient(obj)
    assert_eq_str(row.id, "p1", "id")
    assert_true(row.gender.value() == "female", "gender")
    assert_true(row.birth_date.value() == "1990-01-01", "birth_date")
    assert_true(not row.family_name, "family_name should be null")
    assert_true(not row.given_name, "given_name should be null")
    assert_true(not row.deceased, "deceased should be null")


def test_shred_patient_with_name() raises:
    """Name[0].family and name[0].given[0] are extracted when present."""
    var obj = parse_json(
        '{"id": "p2", "name": [{"family": "Smith", "given": ["Jane", "Q"]}]}'
    )
    var row = shred_patient(obj)
    assert_true(row.family_name.value() == "Smith", "family_name")
    assert_true(row.given_name.value() == "Jane", "given_name (first only)")


def test_shred_patient_deceased_boolean() raises:
    """DeceasedBoolean=true is extracted as deceased=True."""
    var obj = parse_json('{"id": "p3", "deceasedBoolean": true}')
    var row = shred_patient(obj)
    assert_true(row.deceased.value() == True, "deceased true")


def test_shred_patient_missing_id_raises() raises:
    """Id is the one required field: missing it is an error, not a null row."""
    var obj = parse_json('{"gender": "male"}')
    var raised = False
    try:
        _ = shred_patient(obj)
    except:
        raised = True
    assert_true(raised, "missing id should raise")


def main() raises:
    test_shred_patient_minimal()
    print("PASS test_shred_patient_minimal")

    test_shred_patient_with_name()
    print("PASS test_shred_patient_with_name")

    test_shred_patient_deceased_boolean()
    print("PASS test_shred_patient_deceased_boolean")

    test_shred_patient_missing_id_raises()
    print("PASS test_shred_patient_missing_id_raises")

    print("\nAll resource tests passed.")
