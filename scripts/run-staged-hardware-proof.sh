#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 sermon APP_PATH INPUT_UID OUTPUT_UID PROFILE_PATH EVIDENCE_ROOT"
  print -u2 "  $0 worship APP_PATH INPUT_UID OUTPUT_UID PROFILE_PATH EVIDENCE_ROOT SERMON_MANIFEST SERMON_ACCEPTANCE_DIR TRUSTED_SIGNERS"
  print -u2 ""
  print -u2 "Optional environment: STABILITY_SECONDS=7200 SOUNDCHECK_SECONDS=30 RECORDING_RESERVE_GB=20"
  print -u2 "Short engineering runs require REHEARSAL_ONLY=1 and never mint production proof."
}

if (( $# < 6 )); then
  usage
  exit 2
fi

phase="$1"
app_path="$2"
input_uid="$3"
output_uid="$4"
profile_path="$5"
evidence_root="$6"
sermon_manifest="${7:-}"
sermon_acceptance_directory="${8:-}"
trusted_signers="${9:-}"
stability_seconds="${STABILITY_SECONDS:-7200}"
soundcheck_seconds="${SOUNDCHECK_SECONDS:-30}"
recording_reserve_gb="${RECORDING_RESERVE_GB:-20}"
rehearsal_only="${REHEARSAL_ONLY:-0}"
app_binary="${app_path}/Contents/MacOS/AutoMix Native"
script_directory="${0:A:h}"

if [[ "${phase}" != "sermon" && "${phase}" != "worship" ]]; then
  usage
  exit 2
fi
if [[ ! -x "${app_binary}" ]]; then
  print -u2 "AutoMix executable not found or not executable: ${app_binary}"
  exit 2
fi
if [[ ! -f "${profile_path}" ]]; then
  print -u2 "Venue profile not found: ${profile_path}"
  exit 2
fi
if [[ ! "${stability_seconds}" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  print -u2 "STABILITY_SECONDS must be numeric."
  exit 2
fi
if (( ${stability_seconds%.*} < 30 || ${stability_seconds%.*} > 14400 )); then
  print -u2 "STABILITY_SECONDS must be between 30 and 14400."
  exit 2
fi
if [[ ! "${soundcheck_seconds}" =~ '^[0-9]+([.][0-9]+)?$' ]] ||
    (( ${soundcheck_seconds%.*} < 1 || ${soundcheck_seconds%.*} > 30 )); then
  print -u2 "SOUNDCHECK_SECONDS must be between 1 and 30."
  exit 2
fi
if [[ ! "${recording_reserve_gb}" =~ '^[0-9]+([.][0-9]+)?$' ]] ||
    (( ${recording_reserve_gb%.*} < 5 || ${recording_reserve_gb%.*} > 500 )); then
  print -u2 "RECORDING_RESERVE_GB must be between 5 and 500."
  exit 2
fi
if [[ "${rehearsal_only}" != "0" && "${rehearsal_only}" != "1" ]]; then
  print -u2 "REHEARSAL_ONLY must be 0 or 1."
  exit 2
fi
if (( ${stability_seconds%.*} < 7200 )) && [[ "${rehearsal_only}" != "1" ]]; then
  print -u2 "Production proof requires at least 7200 seconds. Set REHEARSAL_ONLY=1 for a shorter engineering run."
  exit 2
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
phase_directory="${evidence_root}/${phase}-${timestamp}"
/bin/mkdir -p "${phase_directory}"
app_integrity_report="${phase_directory}/app-integrity.txt"

# A rehearsal build can exercise every software check but cannot mint production
# hardware proof. Bind the evidence to an intact, notarized, Gatekeeper-accepted app.
: > "${app_integrity_report}"
if ! /usr/bin/codesign --verify --deep --strict --verbose=2 \
    "${app_path}" >> "${app_integrity_report}" 2>&1; then
  print -u2 "Hardware proof requires an intact signed app; inspect ${app_integrity_report}."
  exit 3
fi
/usr/bin/codesign -dv --verbose=4 "${app_path}" >> "${app_integrity_report}" 2>&1
if ! /usr/bin/xcrun stapler validate \
    "${app_path}" >> "${app_integrity_report}" 2>&1; then
  print -u2 "Hardware proof requires a stapled notarization ticket; inspect ${app_integrity_report}."
  exit 3
fi
if ! /usr/sbin/spctl --assess --type execute --verbose=4 \
    "${app_path}" >> "${app_integrity_report}" 2>&1; then
  print -u2 "Hardware proof requires Gatekeeper acceptance; inspect ${app_integrity_report}."
  exit 3
fi
/usr/bin/shasum -a 256 "${app_binary}" >> "${app_integrity_report}"

encoder_health_url="$(/usr/bin/plutil -extract encoderHealthURL raw -o - "${profile_path}" 2>/dev/null || true)"
egress_health_url="$(/usr/bin/plutil -extract egressHealthURL raw -o - "${profile_path}" 2>/dev/null || true)"
if [[ -z "${encoder_health_url}" || -z "${egress_health_url}" ]]; then
  print -u2 "Both encoderHealthURL and egressHealthURL must be configured in the venue profile."
  exit 3
fi

if [[ "${phase}" == "worship" ]]; then
  if [[ -z "${sermon_manifest}" ||
        -z "${sermon_acceptance_directory}" ||
        -z "${trusted_signers}" ]]; then
    print -u2 "Worship proof requires a verified sermon manifest, signed acceptance bundle, and trusted-signer file."
    usage
    exit 2
  fi
  if [[ ! -f "${sermon_manifest}" ]]; then
    print -u2 "Sermon manifest not found: ${sermon_manifest}"
    exit 2
  fi
  "${app_binary}" --smoke-test --verify-full-check --manifest "${sermon_manifest}"
  sermon_scene="$(/usr/bin/plutil -extract scene raw -o - "${sermon_manifest}")"
  sermon_hardware="$(/usr/bin/plutil -extract hardwareProofPassed raw -o - "${sermon_manifest}")"
  if [[ "${sermon_scene}" != "sermon" || "${sermon_hardware}" != "true" ]]; then
    print -u2 "Worship is blocked: the supplied manifest is not passed sermon hardware proof."
    exit 3
  fi
  "${script_directory}/verify-proof-acceptance.sh" \
    --acceptance-dir "${sermon_acceptance_directory}" \
    --trusted-signers "${trusted_signers}" \
    --expected-phase sermon \
    --expected-decision approved \
    --manifest "${sermon_manifest}"
fi

health_stop_file="${phase_directory}/.stop-health-monitor"
health_failure_file="${phase_directory}/.stream-health-failed"
health_log="${phase_directory}/stream-health-observations.tsv"
print -r -- $'checkedAtMs\tprobe\tstate\tresponseTimestampMs\tageMs\thealthy\tstreaming\taudioActive\tdetail' > "${health_log}"

monitor_health_endpoint() {
  local probe_name="$1"
  local probe_url="$2"
  local consecutive_failures=0
  local response_file="${phase_directory}/.${probe_name}-health-response.json"

  while [[ ! -e "${health_stop_file}" ]]; do
    local now_ms="$(( $(date +%s) * 1000 ))"
    local state="healthy"
    local detail="fresh live payload"
    local healthy=""
    local streaming=""
    local audio_active=""
    local observed_ms=""
    local age_ms=""
    if ! /usr/bin/curl --silent --show-error --fail --max-time 3 \
      -H "Accept: application/json" \
      -o "${response_file}" \
      "${probe_url}"; then
      state="unhealthy"
      detail="HTTP request failed"
    else
      healthy="$(/usr/bin/plutil -extract healthy raw -o - "${response_file}" 2>/dev/null || true)"
      streaming="$(/usr/bin/plutil -extract streaming raw -o - "${response_file}" 2>/dev/null || true)"
      audio_active="$(/usr/bin/plutil -extract audioActive raw -o - "${response_file}" 2>/dev/null || true)"
      observed_ms="$(/usr/bin/plutil -extract timestampMs raw -o - "${response_file}" 2>/dev/null || true)"
      if [[ "${healthy}" != "true" || "${streaming}" != "true" || "${audio_active}" != "true" ||
            ! "${observed_ms}" =~ '^[0-9]+$' ]]; then
        state="unhealthy"
        detail="invalid or unhealthy JSON contract"
      else
        age_ms="$(( now_ms - observed_ms ))"
        if (( age_ms < -5000 || age_ms > 15000 )); then
          state="unhealthy"
          detail="stale or future health timestamp"
        fi
      fi
    fi

    print -r -- "${now_ms}"$'\t'"${probe_name}"$'\t'"${state}"$'\t'"${observed_ms}"$'\t'"${age_ms}"$'\t'"${healthy}"$'\t'"${streaming}"$'\t'"${audio_active}"$'\t'"${detail}" >> "${health_log}"
    if [[ "${state}" == "healthy" ]]; then
      consecutive_failures=0
      /usr/bin/touch "${phase_directory}/.${probe_name}-health-seen"
    else
      consecutive_failures="$(( consecutive_failures + 1 ))"
      if (( consecutive_failures >= 2 )); then
        /usr/bin/touch "${health_failure_file}"
      fi
    fi
    /bin/sleep 2
  done
  /bin/rm -f "${response_file}"
}

typeset -a health_monitor_pids
monitor_health_endpoint "encoder" "${encoder_health_url}" &
health_monitor_pids+=("$!")
monitor_health_endpoint "egress" "${egress_health_url}" &
health_monitor_pids+=("$!")

stop_health_monitors() {
  /usr/bin/touch "${health_stop_file}"
  local monitor_pid
  for monitor_pid in "${health_monitor_pids[@]}"; do
    wait "${monitor_pid}" 2>/dev/null || true
  done
  /bin/rm -f "${health_stop_file}"
}
trap stop_health_monitors EXIT INT TERM

proof_started_ms="$(( $(date +%s) * 1000 ))"
"${app_binary}" \
  --smoke-test \
  --core-audio-full-check \
  --input-uid "${input_uid}" \
  --output-uid "${output_uid}" \
  --profile "${profile_path}" \
  --expected-inputs 64 \
  --scene "${phase}" \
  --soundcheck-seconds "${soundcheck_seconds}" \
  --stability-seconds "${stability_seconds}" \
  --continuous-recording \
  --recording-reserve-gb "${recording_reserve_gb}" \
  --output-dir "${phase_directory}"
proof_ended_ms="$(( $(date +%s) * 1000 ))"

stop_health_monitors
trap - EXIT INT TERM

if [[ -e "${health_failure_file}" ||
      ! -e "${phase_directory}/.encoder-health-seen" ||
      ! -e "${phase_directory}/.egress-health-seen" ]]; then
  print -u2 "Stream health proof failed; inspect ${health_log}."
  exit 5
fi
/bin/rm -f \
  "${health_failure_file}" \
  "${phase_directory}/.encoder-health-seen" \
  "${phase_directory}/.egress-health-seen"

manifests=("${phase_directory}"/automix-core-audio-full-check-*.json(N))
if (( ${#manifests} != 1 )); then
  print -u2 "Expected exactly one full-check manifest in ${phase_directory}; found ${#manifests}."
  exit 4
fi

manifest="${manifests[1]}"
"${app_binary}" --smoke-test --verify-full-check --manifest "${manifest}"
stream_health_arguments=(
  --stream-health "${health_log}"
  --manifest "${manifest}"
  --expected-phase "${phase}"
)
if [[ "${rehearsal_only}" != "1" ]]; then
  stream_health_arguments+=(--require-production-duration)
fi
"${script_directory}/verify-stream-health-evidence.sh" \
  "${stream_health_arguments[@]}"

incident_journal_path="${AUTOMIX_INCIDENT_JOURNAL_PATH:-${HOME}/Library/Application Support/AutoMix Native/Incidents/runtime-incidents.jsonl}"
incident_report="${phase_directory}/runtime-incident-evidence.json"
incident_arguments=(
  --journal "${incident_journal_path}"
  --manifest "${manifest}"
  --phase "${phase}"
  --window-start-ms "${proof_started_ms}"
  --window-end-ms "${proof_ended_ms}"
  --output "${incident_report}"
)
if [[ "${rehearsal_only}" != "1" ]]; then
  incident_arguments+=(--require-production-duration)
fi
"${script_directory}/record-runtime-incident-evidence.sh" \
  "${incident_arguments[@]}"

recording_reports=(
  "${phase_directory}"/automix-continuous-recording-*/continuous-recording-proof.json(N)
)
if (( ${#recording_reports} != 1 )); then
  print -u2 "Expected exactly one continuous recording proof report in ${phase_directory}; found ${#recording_reports}."
  exit 4
fi
recording_report="${recording_reports[1]}"
if [[ "${rehearsal_only}" == "1" ]]; then
  "${app_binary}" \
    --smoke-test \
    --verify-continuous-recording \
    --recording-report "${recording_report}"
  print "${phase:u} rehearsal passed; production proof was not minted: ${manifest}"
else
  "${app_binary}" \
    --smoke-test \
    --verify-continuous-recording \
    --recording-report "${recording_report}" \
    --require-production-duration
  print "${phase:u} hardware proof passed: ${manifest}"
  print "${phase:u} continuous recording proof passed: ${recording_report}"
  print "${phase:u} runtime incident proof passed: ${incident_report}"
  print "Review the complete evidence, then record the post-review decision with scripts/record-proof-acceptance.sh."
fi
