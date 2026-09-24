#!/usr/bin/env bash
# gen_synthea_data.sh: generate a Bulk-FHIR-shaped NDJSON dataset with
# Synthea, for benchmarking fhir-arrow against a Python baseline.
#
# Usage: bench/gen_synthea_data.sh [population] [state] [out_dir]
#   population defaults to 500 (approx. matches ~577 patients / ~270k
#   observations / ~19k conditions in the numbers recorded in the README)
#   state       defaults to Massachusetts
#   out_dir     defaults to /tmp/synthea_out
#
# Requires Java 11+ on PATH. Downloads the Synthea release jar
# (synthea-with-dependencies.jar, ~200 MB, one-time) to ~/.cache/synthea/
# if not already present.

set -euo pipefail

POPULATION="${1:-500}"
STATE="${2:-Massachusetts}"
OUT_DIR="${3:-/tmp/synthea_out}"

SYNTHEA_VERSION="v4.0.0"
CACHE_DIR="$HOME/.cache/synthea"
JAR_PATH="$CACHE_DIR/synthea-with-dependencies.jar"

if ! command -v java >/dev/null 2>&1; then
  echo "ERROR: Java is required (Synthea is a JVM application). Install Java 11+ and ensure java is on PATH." >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"
if [[ ! -f "$JAR_PATH" ]]; then
  echo "Downloading Synthea $SYNTHEA_VERSION (~200 MB, one-time)..."
  curl -fsSL -o "$JAR_PATH" \
    "https://github.com/synthetichealth/synthea/releases/download/${SYNTHEA_VERSION}/synthea-with-dependencies.jar"
fi

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

java -jar "$JAR_PATH" \
  --exporter.fhir.export=true \
  --exporter.fhir.bulk_data=true \
  --exporter.hospital.fhir.export=false \
  --exporter.practitioner.fhir.export=false \
  -p "$POPULATION" "$STATE"

echo
echo "Bulk FHIR NDJSON written to: $OUT_DIR/output/fhir/"
echo "  Patient.ndjson, Observation.ndjson, Condition.ndjson (plus other resource types, unused by fhir-arrow's v0 scope)"
