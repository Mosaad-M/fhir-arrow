from resources import (
    PatientRow, shred_patient,
    ObservationRow, shred_observation,
    ConditionRow, shred_condition,
)
from json import parse_json


def assert_true(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("FAIL: " + msg)


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


# ── Observation ──────────────────────────────────────────────────────────────


def test_shred_observation_value_quantity() raises:
    """valueQuantity populates value_quantity/value_unit; value_string stays null."""
    var obj = parse_json(
        '{"id": "o1", "status": "final",'
        ' "subject": {"reference": "Patient/p1"},'
        ' "code": {"coding": [{"system": "http://loinc.org", "code": "4548-4",'
        ' "display": "Hemoglobin A1c"}]},'
        ' "effectiveDateTime": "2024-01-01T00:00:00Z",'
        ' "valueQuantity": {"value": 5.4, "unit": "%"}}'
    )
    var row = shred_observation(obj)
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


def test_shred_observation_value_string() raises:
    """valueString populates value_string; value_quantity/value_unit stay null."""
    var obj = parse_json(
        '{"id": "o2", "code": {"coding": [{"code": "obs-note"}]},'
        ' "valueString": "no acute findings"}'
    )
    var row = shred_observation(obj)
    assert_eq_str(row.value_string.value(), "no acute findings", "value_string")
    assert_true(not row.value_quantity, "value_quantity should be null")
    assert_true(not row.value_unit, "value_unit should be null")


def test_shred_observation_no_value() raises:
    """An Observation with neither valueQuantity nor valueString shreds cleanly (no crash), both value columns null."""
    var obj = parse_json('{"id": "o3", "code": {"coding": [{"code": "x"}]}}')
    var row = shred_observation(obj)
    assert_true(not row.value_quantity, "value_quantity should be null")
    assert_true(not row.value_string, "value_string should be null")


def test_shred_observation_missing_id_raises() raises:
    """id is required for Observation too."""
    var obj = parse_json('{"status": "final"}')
    var raised = False
    try:
        _ = shred_observation(obj)
    except:
        raised = True
    assert_true(raised, "missing id should raise")


# ── Condition ────────────────────────────────────────────────────────────────


def test_shred_condition_full() raises:
    """onsetDateTime and clinicalStatus.coding[0].code are extracted when present."""
    var obj = parse_json(
        '{"id": "c1", "subject": {"reference": "Patient/p1"},'
        ' "code": {"coding": [{"code": "44054006", "display": "Diabetes"}]},'
        ' "clinicalStatus": {"coding": [{"code": "active"}]},'
        ' "onsetDateTime": "2020-05-01",'
        ' "recordedDate": "2020-05-02"}'
    )
    var row = shred_condition(obj)
    assert_eq_str(row.id, "c1", "id")
    assert_eq_str(row.patient_ref.value(), "Patient/p1", "patient_ref")
    assert_eq_str(row.code.value(), "44054006", "code")
    assert_eq_str(row.code_display.value(), "Diabetes", "code_display")
    assert_eq_str(row.clinical_status.value(), "active", "clinical_status")
    assert_eq_str(row.onset_datetime.value(), "2020-05-01", "onset_datetime")
    assert_eq_str(row.recorded_date.value(), "2020-05-02", "recorded_date")


def test_shred_condition_no_onset() raises:
    """A Condition with no onsetDateTime shreds cleanly, onset_datetime null."""
    var obj = parse_json(
        '{"id": "c2", "code": {"coding": [{"code": "x"}]}}'
    )
    var row = shred_condition(obj)
    assert_true(not row.onset_datetime, "onset_datetime should be null")


def test_shred_condition_missing_id_raises() raises:
    """id is required for Condition too."""
    var obj = parse_json('{"code": {"coding": [{"code": "x"}]}}')
    var raised = False
    try:
        _ = shred_condition(obj)
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

    test_shred_observation_value_quantity()
    print("PASS test_shred_observation_value_quantity")

    test_shred_observation_value_string()
    print("PASS test_shred_observation_value_string")

    test_shred_observation_no_value()
    print("PASS test_shred_observation_no_value")

    test_shred_observation_missing_id_raises()
    print("PASS test_shred_observation_missing_id_raises")

    test_shred_condition_full()
    print("PASS test_shred_condition_full")

    test_shred_condition_no_onset()
    print("PASS test_shred_condition_no_onset")

    test_shred_condition_missing_id_raises()
    print("PASS test_shred_condition_missing_id_raises")

    print("\nAll resource tests passed.")
