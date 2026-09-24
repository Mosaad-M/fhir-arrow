# resources.mojo: FHIR resource row structs.
#
# The v0 field scope for each resource type (documented in the README) lives
# here as plain row structs. The extraction logic that fills them lives in
# fast_shred.mojo (shred_patient_fast/shred_observation_fast/
# shred_condition_fast): a zero-tree byte scanner, not a JsonValue-tree
# walk, since that tree-building step was the dominant cost identified by
# the v0 benchmark. Only a missing `id` raises; every other v0 field is
# simply left null when absent.


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
