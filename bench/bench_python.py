#!/usr/bin/env python3
"""Python baseline for the fhir-arrow benchmark.

Mirrors exactly the same v0 field-shredding scope as resources.mojo (see the
README's field-mapping table) so the comparison is apples to apples: same
input files, same fields extracted, same output format (Feather). Uses the
"typical" approach a data engineer would actually reach for (plain `json` +
`pandas`/`pyarrow`), not a heavier FHIR-validating library like
`fhir.resources`, since that does meaningfully more work (schema
validation) than this benchmark is measuring.

Usage: python3 bench_python.py <synthea_fhir_dir> <out_dir>
"""

import json
import sys
import time

import pandas as pd


def _coding0(obj):
    code = obj.get("code")
    if not code:
        return None
    coding = code.get("coding")
    if not coding:
        return None
    return coding[0]


def shred_patient(obj):
    name0 = (obj.get("name") or [None])[0]
    family = name0.get("family") if name0 else None
    given_list = name0.get("given") if name0 else None
    given = given_list[0] if given_list else None
    return {
        "id": obj["id"],
        "gender": obj.get("gender"),
        "birth_date": obj.get("birthDate"),
        "family_name": family,
        "given_name": given,
        "deceased": obj.get("deceasedBoolean"),
    }


def shred_observation(obj):
    subject = obj.get("subject") or {}
    c0 = _coding0(obj) or {}
    vq = obj.get("valueQuantity")
    return {
        "id": obj["id"],
        "patient_ref": subject.get("reference"),
        "code": c0.get("code"),
        "code_system": c0.get("system"),
        "code_display": c0.get("display"),
        "status": obj.get("status"),
        "effective_datetime": obj.get("effectiveDateTime"),
        "value_quantity": vq.get("value") if vq else None,
        "value_unit": vq.get("unit") if vq else None,
        "value_string": obj.get("valueString"),
    }


def shred_condition(obj):
    subject = obj.get("subject") or {}
    c0 = _coding0(obj) or {}
    clinical_status = obj.get("clinicalStatus") or {}
    cs_coding = (clinical_status.get("coding") or [None])[0]
    return {
        "id": obj["id"],
        "patient_ref": subject.get("reference"),
        "code": c0.get("code"),
        "code_display": c0.get("display"),
        "clinical_status": cs_coding.get("code") if cs_coding else None,
        "onset_datetime": obj.get("onsetDateTime"),
        "recorded_date": obj.get("recordedDate"),
    }


SHREDDERS = {
    "Patient": shred_patient,
    "Observation": shred_observation,
    "Condition": shred_condition,
}


def run_one(label, ndjson_path, out_path, shredder):
    t0 = time.perf_counter()
    rows = []
    with open(ndjson_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            rows.append(shredder(obj))
    df = pd.DataFrame(rows)
    df.to_feather(out_path)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    n = len(rows)
    rows_per_sec = n / (elapsed_ms / 1000.0) if elapsed_ms > 0 else float("inf")
    print(f"{label}: {n} records in {elapsed_ms:.1f} ms ({rows_per_sec:.0f} rows/sec)")


def main():
    if len(sys.argv) < 3:
        print("usage: bench_python.py <synthea_fhir_dir> <out_dir>")
        sys.exit(1)
    fhir_dir, out_dir = sys.argv[1], sys.argv[2]

    run_one("Patient", f"{fhir_dir}/Patient.ndjson", f"{out_dir}/patients_py.feather", shred_patient)
    run_one("Observation", f"{fhir_dir}/Observation.ndjson", f"{out_dir}/observations_py.feather", shred_observation)
    run_one("Condition", f"{fhir_dir}/Condition.ndjson", f"{out_dir}/conditions_py.feather", shred_condition)


if __name__ == "__main__":
    main()
