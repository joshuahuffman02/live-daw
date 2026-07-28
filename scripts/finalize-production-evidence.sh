#!/bin/zsh
set -euo pipefail

TRAPZERR() {
  local failure_code="$?"
  print -u2 "production evidence finalization failed: status=${failure_code} at ${funcfiletrace[1]:-unknown}"
  return "${failure_code}"
}

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --draft-dir DIR --manifest PATH --candidate-commit SHA --output-dir DIR"
  print -u2 "     [--require-approved-replay] [--replace]"
}

draft_directory=""
manifest_path=""
candidate_commit=""
output_directory=""
require_approved_replay=0
replace_existing=0
while (( $# > 0 )); do
  case "$1" in
    --draft-dir) draft_directory="${2:-}"; shift 2 ;;
    --manifest) manifest_path="${2:-}"; shift 2 ;;
    --candidate-commit) candidate_commit="${2:-}"; shift 2 ;;
    --output-dir) output_directory="${2:-}"; shift 2 ;;
    --require-approved-replay) require_approved_replay=1; shift ;;
    --replace) replace_existing=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      print -u2 "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${draft_directory}" ||
      -z "${manifest_path}" ||
      -z "${output_directory}" ||
      ! "${candidate_commit}" =~ '^[0-9a-f]{40}$' ||
      ! -s "${manifest_path}" ]]; then
  usage
  exit 2
fi

draft_directory="$(/bin/realpath "${draft_directory}")"
/bin/mkdir -p "${output_directory}"
output_directory="$(/bin/realpath "${output_directory}")"
if [[ "${draft_directory}" == "${output_directory}" ]]; then
  print -u2 "Draft and finalized output directories must differ."
  exit 3
fi

names=(
  external-failover
  latency-lipsync
  runtime-resilience
  replay-comparison
)
for name in "${names[@]}"; do
  if [[ ! -s "${draft_directory}/${name}.json" ]]; then
    print -u2 "Required draft is missing or empty: ${draft_directory}/${name}.json"
    exit 3
  fi
  if [[ -e "${output_directory}/${name}.json" ]] && (( ! replace_existing )); then
    print -u2 "Finalized report exists; pass --replace to overwrite it: ${output_directory}/${name}.json"
    exit 3
  fi
done

phase="$(/usr/bin/plutil -extract scene raw -o - "${manifest_path}" 2>/dev/null || true)"
if [[ "${phase}" != "sermon" && "${phase}" != "worship" ]]; then
  print -u2 "Full-check manifest scene must be sermon or worship."
  exit 3
fi
manifest_sha="$(/usr/bin/shasum -a 256 "${manifest_path}" | /usr/bin/awk '{print $1}')"
completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
temporary_directory="$(/usr/bin/mktemp -d "${output_directory}/.production-evidence-finalize.XXXXXX")"
cleanup() {
  if [[ "${temporary_directory:-}" == "${output_directory}/.production-evidence-finalize."* &&
        -d "${temporary_directory}" ]]; then
    /bin/rm -rf "${temporary_directory}"
  fi
}
trap cleanup EXIT INT TERM

for name in "${names[@]}"; do
  report="${temporary_directory}/${name}.json"
  /bin/cp "${draft_directory}/${name}.json" "${report}"
  /usr/bin/plutil -p "${report}" >/dev/null
  /usr/bin/plutil -replace formatVersion -integer 1 "${report}"
  /usr/bin/plutil -replace phase -string "${phase}" "${report}"
  /usr/bin/plutil -replace completedAtUTC -string "${completed_at}" "${report}"
  /usr/bin/plutil -replace fullCheckManifestSHA256 -string "${manifest_sha}" "${report}"
  /usr/bin/plutil -remove draft "${report}" 2>/dev/null || true
  /usr/bin/plutil -remove draftInstructions "${report}" 2>/dev/null || true
done
/usr/bin/plutil -replace candidateCommit -string "${candidate_commit}" \
  "${temporary_directory}/replay-comparison.json"

finalize_reference() {
  local report="$1"
  local prefix="$2"
  local label="$3"
  local path canonical_path sha256 byte_count
  path="$(/usr/bin/plutil -extract "${prefix}.path" raw -o - "${report}" 2>/dev/null || true)"
  if [[ "${path}" != /* || ! -s "${path}" ]]; then
    print -u2 "${label} must name a non-empty absolute attachment path."
    exit 4
  fi
  canonical_path="$(/bin/realpath "${path}")"
  sha256="$(/usr/bin/shasum -a 256 "${canonical_path}" | /usr/bin/awk '{print $1}')"
  byte_count="$(/usr/bin/stat -f '%z' "${canonical_path}")"
  /usr/bin/plutil -replace "${prefix}.path" -string "${canonical_path}" "${report}"
  /usr/bin/plutil -replace "${prefix}.sha256" -string "${sha256}" "${report}"
  /usr/bin/plutil -replace "${prefix}.bytes" -integer "${byte_count}" "${report}"
}

external="${temporary_directory}/external-failover.json"
finalize_reference "${external}" wiringDiagram "external failover wiring diagram"
external_count="$(/usr/bin/plutil -extract tests raw -o - "${external}" 2>/dev/null || true)"
if [[ ! "${external_count}" =~ '^[0-9]+$' ]]; then
  print -u2 "External failover draft has no tests array."
  exit 4
fi
integer index=0
while (( index < external_count )); do
  finalize_reference "${external}" "tests.${index}.recording" "external failover test ${index} recording"
  index="$(( index + 1 ))"
done

latency="${temporary_directory}/latency-lipsync.json"
finalize_reference "${latency}" rawMeasurements "latency raw measurements"
finalize_reference "${latency}" testRecording "latency test recording"

runtime="${temporary_directory}/runtime-resilience.json"
runtime_count="$(/usr/bin/plutil -extract tests raw -o - "${runtime}" 2>/dev/null || true)"
if [[ ! "${runtime_count}" =~ '^[0-9]+$' ]]; then
  print -u2 "Runtime resilience draft has no tests array."
  exit 4
fi
index=0
while (( index < runtime_count )); do
  finalize_reference "${runtime}" "tests.${index}.evidence" "runtime resilience test ${index} evidence"
  index="$(( index + 1 ))"
done

replay="${temporary_directory}/replay-comparison.json"
comparison_count="$(/usr/bin/plutil -extract comparisons raw -o - "${replay}" 2>/dev/null || true)"
if [[ ! "${comparison_count}" =~ '^[0-9]+$' ]]; then
  print -u2 "Replay comparison draft has no comparisons array."
  exit 4
fi
index=0
while (( index < comparison_count )); do
  prefix="comparisons.${index}"
  finalize_reference "${replay}" "${prefix}.baseline.program" "replay ${index} baseline program"
  finalize_reference "${replay}" "${prefix}.baseline.metrics" "replay ${index} baseline metrics"
  finalize_reference "${replay}" "${prefix}.baseline.decisions" "replay ${index} baseline decisions"
  finalize_reference "${replay}" "${prefix}.candidate.program" "replay ${index} candidate program"
  finalize_reference "${replay}" "${prefix}.candidate.metrics" "replay ${index} candidate metrics"
  finalize_reference "${replay}" "${prefix}.candidate.decisions" "replay ${index} candidate decisions"
  finalize_reference "${replay}" "${prefix}.referenceMix" "replay ${index} reference mix"
  index="$(( index + 1 ))"
done

verify_arguments=(
  --external-failover "${external}"
  --latency-lipsync "${latency}"
  --runtime-resilience "${runtime}"
  --replay-comparison "${replay}"
  --expected-manifest "${manifest_path}"
  --expected-candidate-commit "${candidate_commit}"
  --expected-phase "${phase}"
)
if (( require_approved_replay )); then
  verify_arguments+=(--require-approved-replay)
fi
"${0:A:h}/verify-production-evidence.sh" "${verify_arguments[@]}" >/dev/null

for name in "${names[@]}"; do
  /bin/mv -f "${temporary_directory}/${name}.json" "${output_directory}/${name}.json"
done
trap - EXIT INT TERM
/bin/rm -rf "${temporary_directory}"
print "Finalized and verified ${phase} production evidence in ${output_directory}."
