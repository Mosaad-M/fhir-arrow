# resources.mojo — FHIR resource shredders.
#
# Each shred_<resource>(obj: JsonValue) -> <Resource>Row flattens a subset of
# a FHIR resource's fields (the v0 scope documented in the README) into a
# plain row struct. Fields outside that scope are simply left null, not an
# error — only a missing `id` raises.

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
