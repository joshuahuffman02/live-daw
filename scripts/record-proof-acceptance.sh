#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --phase sermon|worship --decision approved|rejected"
  print -u2 "     --reviewer NAME --signer ID --signing-key PATH --trusted-signers FILE"
  print -u2 "     --source-commit SHA --app APP_PATH --build-metadata PATH --manifest PATH"
  print -u2 "     --recording-report PATH --app-integrity PATH --stream-health PATH"
  print -u2 "     --runtime-incidents PATH"
  print -u2 "     --external-failover PATH --latency-lipsync PATH"
  print -u2 "     --runtime-resilience PATH --replay-comparison PATH"
  print -u2 "     --output-root DIR --notes TEXT"
  print -u2 "     [--sermon-acceptance-dir DIR]"
}

phase=""
decision=""
reviewer=""
signer_identity=""
signing_key=""
trusted_signers=""
source_commit=""
app_path=""
build_metadata_path=""
manifest_path=""
recording_report_path=""
app_integrity_path=""
stream_health_path=""
runtime_incidents_path=""
external_failover_path=""
latency_lipsync_path=""
runtime_resilience_path=""
replay_comparison_path=""
output_root=""
notes=""
sermon_acceptance_directory=""

while (( $# > 0 )); do
  case "$1" in
    --phase) phase="${2:-}"; shift 2 ;;
    --decision) decision="${2:-}"; shift 2 ;;
    --reviewer) reviewer="${2:-}"; shift 2 ;;
    --signer) signer_identity="${2:-}"; shift 2 ;;
    --signing-key) signing_key="${2:-}"; shift 2 ;;
    --trusted-signers) trusted_signers="${2:-}"; shift 2 ;;
    --source-commit) source_commit="${2:-}"; shift 2 ;;
    --app) app_path="${2:-}"; shift 2 ;;
    --build-metadata) build_metadata_path="${2:-}"; shift 2 ;;
    --manifest) manifest_path="${2:-}"; shift 2 ;;
    --recording-report) recording_report_path="${2:-}"; shift 2 ;;
    --app-integrity) app_integrity_path="${2:-}"; shift 2 ;;
    --stream-health) stream_health_path="${2:-}"; shift 2 ;;
    --runtime-incidents) runtime_incidents_path="${2:-}"; shift 2 ;;
    --external-failover) external_failover_path="${2:-}"; shift 2 ;;
    --latency-lipsync) latency_lipsync_path="${2:-}"; shift 2 ;;
    --runtime-resilience) runtime_resilience_path="${2:-}"; shift 2 ;;
    --replay-comparison) replay_comparison_path="${2:-}"; shift 2 ;;
    --output-root) output_root="${2:-}"; shift 2 ;;
    --notes) notes="${2:-}"; shift 2 ;;
    --sermon-acceptance-dir) sermon_acceptance_directory="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      print -u2 "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ ( "${phase}" != "sermon" && "${phase}" != "worship" ) ||
      ( "${decision}" != "approved" && "${decision}" != "rejected" ) ||
      -z "${reviewer}" ||
      ! "${signer_identity}" =~ '^[A-Za-z0-9._@+-]{1,128}$' ||
      ! "${source_commit}" =~ '^[0-9a-f]{40}$' ||
      -z "${app_path}" ||
      -z "${output_root}" ||
      -z "${notes}" ]]; then
  print -u2 "Acceptance metadata is incomplete or invalid."
  usage
  exit 2
fi
if (( ${#reviewer} > 200 || ${#notes} > 2000 )) ||
    [[ "${reviewer}" == *[[:cntrl:]]* ]]; then
  print -u2 "Reviewer must be one line (200 characters maximum); notes may contain at most 2,000 characters."
  exit 2
fi

app_binary="${app_path}/Contents/MacOS/AutoMix Native"
if [[ ! -x "${app_binary}" ]]; then
  print -u2 "AutoMix executable not found or not executable: ${app_binary}"
  exit 3
fi
if [[ ! -f "${signing_key}" || ! -s "${trusted_signers}" ]]; then
  print -u2 "A signing private key and non-empty venue trusted-signers file are required."
  exit 3
fi

typeset -A evidence_paths
evidence_paths=(
  build-metadata "${build_metadata_path}"
  full-check-manifest "${manifest_path}"
  continuous-recording-report "${recording_report_path}"
  app-integrity "${app_integrity_path}"
  stream-health "${stream_health_path}"
  runtime-incidents "${runtime_incidents_path}"
  external-failover "${external_failover_path}"
  latency-lipsync "${latency_lipsync_path}"
  runtime-resilience "${runtime_resilience_path}"
  replay-comparison "${replay_comparison_path}"
)
for label path in "${(@kv)evidence_paths}"; do
  if [[ ! -s "${path}" ]]; then
    print -u2 "Required ${label} evidence is missing or empty: ${path}"
    exit 3
  fi
done

if ! /usr/bin/codesign --verify --deep --strict "${app_path}"; then
  print -u2 "Acceptance requires an intact signed app."
  exit 4
fi
if ! /usr/bin/xcrun stapler validate "${app_path}"; then
  print -u2 "Acceptance requires a stapled notarization ticket."
  exit 4
fi
if ! /usr/sbin/spctl --assess --type execute "${app_path}"; then
  print -u2 "Acceptance requires Gatekeeper approval."
  exit 4
fi
app_binary_sha="$(/usr/bin/shasum -a 256 "${app_binary}" | /usr/bin/awk '{print $1}')"
if ! /usr/bin/grep -Fq "${app_binary_sha}" "${app_integrity_path}"; then
  print -u2 "App integrity evidence does not bind the current executable SHA-256."
  exit 4
fi
build_commit="$(/usr/bin/plutil -extract commit raw -o - "${build_metadata_path}" 2>/dev/null || true)"
if [[ "${build_commit}" != "${source_commit}" ]]; then
  print -u2 "Build metadata does not bind the supplied source commit."
  exit 4
fi

"${app_binary}" \
  --smoke-test \
  --verify-full-check \
  --manifest "${manifest_path}"
"${app_binary}" \
  --smoke-test \
  --verify-continuous-recording \
  --recording-report "${recording_report_path}" \
  --require-production-duration

manifest_scene="$(/usr/bin/plutil -extract scene raw -o - "${manifest_path}" 2>/dev/null || true)"
manifest_hardware="$(/usr/bin/plutil -extract hardwareProofPassed raw -o - "${manifest_path}" 2>/dev/null || true)"
recording_production="$(/usr/bin/plutil -extract productionProofPassed raw -o - "${recording_report_path}" 2>/dev/null || true)"
if [[ "${manifest_scene}" != "${phase}" ||
      "${manifest_hardware}" != "true" ||
      "${recording_production}" != "true" ]]; then
  print -u2 "The selected manifest/recording report is not passed ${phase} production proof."
  exit 4
fi

script_directory="${0:A:h}"
"${script_directory}/verify-stream-health-evidence.sh" \
  --stream-health "${stream_health_path}" \
  --manifest "${manifest_path}" \
  --expected-phase "${phase}" \
  --require-production-duration

"${script_directory}/verify-runtime-incident-evidence.sh" \
  --report "${runtime_incidents_path}" \
  --manifest "${manifest_path}" \
  --expected-phase "${phase}" \
  --require-production-duration

production_evidence_arguments=(
  --external-failover "${external_failover_path}"
  --latency-lipsync "${latency_lipsync_path}"
  --runtime-resilience "${runtime_resilience_path}"
  --replay-comparison "${replay_comparison_path}"
  --expected-manifest "${manifest_path}"
  --expected-candidate-commit "${source_commit}"
  --expected-phase "${phase}"
)
if [[ "${decision}" == "approved" ]]; then
  production_evidence_arguments+=(--require-approved-replay)
fi
"${script_directory}/verify-production-evidence.sh" \
  "${production_evidence_arguments[@]}"

if [[ "${phase}" == "worship" ]]; then
  if [[ -z "${sermon_acceptance_directory}" ]]; then
    print -u2 "Worship acceptance requires --sermon-acceptance-dir."
    exit 3
  fi
  "${script_directory}/verify-proof-acceptance.sh" \
    --acceptance-dir "${sermon_acceptance_directory}" \
    --trusted-signers "${trusted_signers}" \
    --expected-phase sermon \
    --expected-decision approved
  evidence_paths[sermon-acceptance-json]="${sermon_acceptance_directory}/acceptance.json"
  evidence_paths[sermon-acceptance-signature]="${sermon_acceptance_directory}/acceptance.json.sig"
fi

/bin/mkdir -p "${output_root}"
output_root="$(/bin/realpath "${output_root}")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_directory="${output_root}/${phase}-acceptance-${timestamp}"
if [[ -e "${final_directory}" ]]; then
  print -u2 "Acceptance output already exists: ${final_directory}"
  exit 3
fi
bundle_temp="$(/usr/bin/mktemp -d "${output_root}/.${phase}-acceptance.XXXXXX")"
cleanup() {
  if [[ -n "${bundle_temp:-}" &&
        "${bundle_temp}" == "${output_root}/.${phase}-acceptance."* &&
        -d "${bundle_temp}" ]]; then
    /bin/rm -rf "${bundle_temp}"
  fi
}
trap cleanup EXIT INT TERM

acceptance_plist="${bundle_temp}/acceptance.plist"
acceptance_json="${bundle_temp}/acceptance.json"
/usr/bin/plutil -create xml1 "${acceptance_plist}"
/usr/bin/plutil -insert formatVersion -integer 1 "${acceptance_plist}"
/usr/bin/plutil -insert bundleID -string "$(/usr/bin/uuidgen)" "${acceptance_plist}"
/usr/bin/plutil -insert phase -string "${phase}" "${acceptance_plist}"
/usr/bin/plutil -insert decision -string "${decision}" "${acceptance_plist}"
/usr/bin/plutil -insert reviewer -string "${reviewer}" "${acceptance_plist}"
/usr/bin/plutil -insert signerIdentity -string "${signer_identity}" "${acceptance_plist}"
/usr/bin/plutil -insert sourceCommit -string "${source_commit}" "${acceptance_plist}"
/usr/bin/plutil -insert reviewedAtUTC -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${acceptance_plist}"
/usr/bin/plutil -insert notes -string "${notes}" "${acceptance_plist}"
if [[ "${phase}" == "sermon" ]]; then
  /usr/bin/plutil -insert decisionScope -string "advance to supervised worship proof" "${acceptance_plist}"
else
  /usr/bin/plutil -insert decisionScope -string "production go-live" "${acceptance_plist}"
fi

/usr/bin/ssh-keygen -y -f "${signing_key}" > "${bundle_temp}/signer.pub"
signer_public_key="$(<"${bundle_temp}/signer.pub")"
/usr/bin/plutil -insert signerPublicKey -string "${signer_public_key}" "${acceptance_plist}"
/usr/bin/plutil -insert evidence -json '[]' "${acceptance_plist}"

integer evidence_index=0
for label in ${(ok)evidence_paths}; do
  path="${evidence_paths[${label}]}"
  canonical_path="$(/bin/realpath "${path}")"
  sha256="$(/usr/bin/shasum -a 256 "${canonical_path}" | /usr/bin/awk '{print $1}')"
  byte_count="$(/usr/bin/stat -f '%z' "${canonical_path}")"
  /usr/bin/plutil -insert "evidence.${evidence_index}" -json '{}' "${acceptance_plist}"
  /usr/bin/plutil -insert "evidence.${evidence_index}.label" -string "${label}" "${acceptance_plist}"
  /usr/bin/plutil -insert "evidence.${evidence_index}.path" -string "${canonical_path}" "${acceptance_plist}"
  /usr/bin/plutil -insert "evidence.${evidence_index}.sha256" -string "${sha256}" "${acceptance_plist}"
  /usr/bin/plutil -insert "evidence.${evidence_index}.bytes" -integer "${byte_count}" "${acceptance_plist}"
  evidence_index="$(( evidence_index + 1 ))"
done

/usr/bin/plutil -convert json -o "${acceptance_json}" "${acceptance_plist}"
/bin/rm "${acceptance_plist}"
/usr/bin/ssh-keygen -Y sign \
  -f "${signing_key}" \
  -n "live-daw-acceptance" \
  "${acceptance_json}"

"${script_directory}/verify-proof-acceptance.sh" \
  --acceptance-dir "${bundle_temp}" \
  --trusted-signers "${trusted_signers}" \
  --expected-phase "${phase}" \
  --expected-decision "${decision}" \
  --manifest "${manifest_path}"

/bin/mv "${bundle_temp}" "${final_directory}"
bundle_temp=""
trap - EXIT INT TERM

"${script_directory}/verify-proof-acceptance.sh" \
  --acceptance-dir "${final_directory}" \
  --trusted-signers "${trusted_signers}" \
  --expected-phase "${phase}" \
  --expected-decision "${decision}" \
  --manifest "${manifest_path}"

print "Recorded signed ${phase} acceptance: ${final_directory}"
