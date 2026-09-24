# resources.mojo: FHIR resource shredders.
#
# Each shred_<resource>(obj: JsonValue) -> <Resource>Row flattens a subset of
# a FHIR resource's fields (the v0 scope documented in the README) into a
# plain row struct. Fields outside that scope are simply left null, not an
# error: only a missing `id` raises.

from json import JsonValue


# ── Patient ──────────────────────────────────────────────────────────────────


struct PatientRow(Copyable, Movable):
    var id: String
    var gender: Optional[String]
    var birth_date: Optional[String]
    var family_name: Optional[String]
    var given_name: Optional[String]
    var deceased: Optional[Bool]

    def __init__(
        out self,
        id: String,
        gender: Optional[String],
        birth_date: Optional[String],
        family_name: Optional[String],
        given_name: Optional[String],
        deceased: Optional[Bool],
    ):
        self.id = id
        self.gender = gender
        self.birth_date = birth_date
        self.family_name = family_name
        self.given_name = given_name
        self.deceased = deceased

    def __init__(out self, *, copy: Self):
        self.id = copy.id
        self.gender = copy.gender
        self.birth_date = copy.birth_date
        self.family_name = copy.family_name
        self.given_name = copy.given_name
        self.deceased = copy.deceased

    def __init__(out self, *, deinit move: Self):
        self.id = move.id^
        self.gender = move.gender^
        self.birth_date = move.birth_date^
        self.family_name = move.family_name^
        self.given_name = move.given_name^
        self.deceased = move.deceased^


def _opt_string(obj: JsonValue, key: String) raises -> Optional[String]:
    if obj.has_key(key):
        return Optional[String](obj.get_string(key))
    return Optional[String](None)


def _coding0(obj: JsonValue) raises -> Optional[JsonValue]:
    """First entry of obj.code.coding[], if code/coding are present and non-empty."""
    if not obj.has_key("code"):
        return Optional[JsonValue](None)
    var code = obj.get("code")
    if not code.has_key("coding") or code.get_array_len("coding") == 0:
        return Optional[JsonValue](None)
    return Optional[JsonValue](code.get("coding").get(0))


def shred_patient(obj: JsonValue) raises -> PatientRow:
    """Flatten a FHIR Patient resource into a PatientRow.

    v0 scope: id, gender, birthDate, name[0].family, name[0].given[0],
    deceasedBoolean. `deceasedDateTime` and additional name entries are out
    of scope and left null.
    """
    if not obj.has_key("id"):
        raise Error("resources: shred_patient: missing required field 'id'")
    var id = obj.get_string("id")

    var gender = _opt_string(obj, "gender")
    var birth_date = _opt_string(obj, "birthDate")

    var family_name = Optional[String](None)
    var given_name = Optional[String](None)
    if obj.has_key("name") and obj.get_array_len("name") > 0:
        var name0 = obj.get("name").get(0)
        if name0.has_key("family"):
            family_name = Optional[String](name0.get_string("family"))
        if name0.has_key("given") and name0.get_array_len("given") > 0:
            given_name = Optional[String](name0.get("given").get_string(0))

    var deceased = Optional[Bool](None)
    if obj.has_key("deceasedBoolean"):
        deceased = Optional[Bool](obj.get_bool("deceasedBoolean"))

    return PatientRow(
        id, gender, birth_date, family_name, given_name, deceased
    )


# ── Observation ──────────────────────────────────────────────────────────────


struct ObservationRow(Copyable, Movable):
    var id: String
    var patient_ref: Optional[String]
    var code: Optional[String]
    var code_system: Optional[String]
    var code_display: Optional[String]
    var status: Optional[String]
    var effective_datetime: Optional[String]
    var value_quantity: Optional[Float64]
    var value_unit: Optional[String]
    var value_string: Optional[String]

    def __init__(
        out self,
        id: String,
        patient_ref: Optional[String],
        code: Optional[String],
        code_system: Optional[String],
        code_display: Optional[String],
        status: Optional[String],
        effective_datetime: Optional[String],
        value_quantity: Optional[Float64],
        value_unit: Optional[String],
        value_string: Optional[String],
    ):
        self.id = id
        self.patient_ref = patient_ref
        self.code = code
        self.code_system = code_system
        self.code_display = code_display
        self.status = status
        self.effective_datetime = effective_datetime
        self.value_quantity = value_quantity
        self.value_unit = value_unit
        self.value_string = value_string

    def __init__(out self, *, copy: Self):
        self.id = copy.id
        self.patient_ref = copy.patient_ref
        self.code = copy.code
        self.code_system = copy.code_system
        self.code_display = copy.code_display
        self.status = copy.status
        self.effective_datetime = copy.effective_datetime
        self.value_quantity = copy.value_quantity
        self.value_unit = copy.value_unit
        self.value_string = copy.value_string

    def __init__(out self, *, deinit move: Self):
        self.id = move.id^
        self.patient_ref = move.patient_ref^
        self.code = move.code^
        self.code_system = move.code_system^
        self.code_display = move.code_display^
        self.status = move.status^
        self.effective_datetime = move.effective_datetime^
        self.value_quantity = move.value_quantity^
        self.value_unit = move.value_unit^
        self.value_string = move.value_string^


def shred_observation(obj: JsonValue) raises -> ObservationRow:
    """Flatten a FHIR Observation resource into an ObservationRow.

    v0 scope: id, subject.reference, code.coding[0] (code/system/display),
    status, effectiveDateTime, and the polymorphic value: valueQuantity
    (value + unit) OR valueString. Other value[x] variants (e.g.
    valueCodeableConcept) are out of scope: both value columns are left
    null, not an error.
    """
    if not obj.has_key("id"):
        raise Error("resources: shred_observation: missing required field 'id'")
    var id = obj.get_string("id")

    var patient_ref = Optional[String](None)
    if obj.has_key("subject") and obj.get("subject").has_key("reference"):
        patient_ref = Optional[String](obj.get("subject").get_string("reference"))

    var code = Optional[String](None)
    var code_system = Optional[String](None)
    var code_display = Optional[String](None)
    var coding0 = _coding0(obj)
    if coding0:
        var c0 = coding0.value().copy()
        if c0.has_key("code"):
            code = Optional[String](c0.get_string("code"))
        if c0.has_key("system"):
            code_system = Optional[String](c0.get_string("system"))
        if c0.has_key("display"):
            code_display = Optional[String](c0.get_string("display"))

    var status = _opt_string(obj, "status")
    var effective_datetime = _opt_string(obj, "effectiveDateTime")

    var value_quantity = Optional[Float64](None)
    var value_unit = Optional[String](None)
    var value_string = Optional[String](None)
    if obj.has_key("valueQuantity"):
        var vq = obj.get("valueQuantity")
        if vq.has_key("value"):
            value_quantity = Optional[Float64](vq.get_number("value"))
        if vq.has_key("unit"):
            value_unit = Optional[String](vq.get_string("unit"))
    elif obj.has_key("valueString"):
        value_string = Optional[String](obj.get_string("valueString"))

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


struct ConditionRow(Copyable, Movable):
    var id: String
    var patient_ref: Optional[String]
    var code: Optional[String]
    var code_display: Optional[String]
    var clinical_status: Optional[String]
    var onset_datetime: Optional[String]
    var recorded_date: Optional[String]

    def __init__(
        out self,
        id: String,
        patient_ref: Optional[String],
        code: Optional[String],
        code_display: Optional[String],
        clinical_status: Optional[String],
        onset_datetime: Optional[String],
        recorded_date: Optional[String],
    ):
        self.id = id
        self.patient_ref = patient_ref
        self.code = code
        self.code_display = code_display
        self.clinical_status = clinical_status
        self.onset_datetime = onset_datetime
        self.recorded_date = recorded_date

    def __init__(out self, *, copy: Self):
        self.id = copy.id
        self.patient_ref = copy.patient_ref
        self.code = copy.code
        self.code_display = copy.code_display
        self.clinical_status = copy.clinical_status
        self.onset_datetime = copy.onset_datetime
        self.recorded_date = copy.recorded_date

    def __init__(out self, *, deinit move: Self):
        self.id = move.id^
        self.patient_ref = move.patient_ref^
        self.code = move.code^
        self.code_display = move.code_display^
        self.clinical_status = move.clinical_status^
        self.onset_datetime = move.onset_datetime^
        self.recorded_date = move.recorded_date^


def shred_condition(obj: JsonValue) raises -> ConditionRow:
    """Flatten a FHIR Condition resource into a ConditionRow.

    v0 scope: id, subject.reference, code.coding[0] (code/display),
    clinicalStatus.coding[0].code, onsetDateTime, recordedDate. Other
    onset[x] variants (e.g. onsetAge, onsetPeriod) are out of scope and
    left null.
    """
    if not obj.has_key("id"):
        raise Error("resources: shred_condition: missing required field 'id'")
    var id = obj.get_string("id")

    var patient_ref = Optional[String](None)
    if obj.has_key("subject") and obj.get("subject").has_key("reference"):
        patient_ref = Optional[String](obj.get("subject").get_string("reference"))

    var code = Optional[String](None)
    var code_display = Optional[String](None)
    var coding0 = _coding0(obj)
    if coding0:
        var c0 = coding0.value().copy()
        if c0.has_key("code"):
            code = Optional[String](c0.get_string("code"))
        if c0.has_key("display"):
            code_display = Optional[String](c0.get_string("display"))

    var clinical_status = Optional[String](None)
    if obj.has_key("clinicalStatus"):
        var cs = obj.get("clinicalStatus")
        if cs.has_key("coding") and cs.get_array_len("coding") > 0:
            var cs0 = cs.get("coding").get(0)
            if cs0.has_key("code"):
                clinical_status = Optional[String](cs0.get_string("code"))

    var onset_datetime = _opt_string(obj, "onsetDateTime")
    var recorded_date = _opt_string(obj, "recordedDate")

    return ConditionRow(
        id,
        patient_ref,
        code,
        code_display,
        clinical_status,
        onset_datetime,
        recorded_date,
    )
