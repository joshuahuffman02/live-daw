#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 sermon APP_PATH INPUT_UID OUTPUT_UID PROFILE_PATH EVIDENCE_ROOT"
  print -u2 "  $0 worship APP_PATH INPUT_UID OUTPUT_UID PROFILE_PATH EVIDENCE_ROOT SERMON_MANIFEST ACCEPTED_BY"
  print -u2 ""
  print -u2 "Optional environment: STABILITY_SECONDS=7200 SOUNDCHECK_SECONDS=30"
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
accepted_by="${8:-}"
stability_seconds="${STABILITY_SECONDS:-7200}"
soundcheck_seconds="${SOUNDCHECK_SECONDS:-30}"
app_binary="${app_path}/Contents/MacOS/AutoMix Native"

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

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
phase_directory="${evidence_root}/${phase}-${timestamp}"
/bin/mkdir -p "${phase_directory}"
encoder_health_url="$(/usr/bin/plutil -extract encoderHealthURL raw -o - "${profile_path}" 2>/dev/null || true)"
egress_health_url="$(/usr/bin/plutil -extract egressHealthURL raw -o - "${profile_path}" 2>/dev/null || true)"
if [[ -z "${encoder_health_url}" || -z "${egress_health_url}" ]]; then
  print -u2 "Both encoderHealthURL and egressHealthURL must be configured in the venue profile."
  exit 3
fi

if [[ "${phase}" == "worship" ]]; then
  if [[ -z "${sermon_manifest}" || -z "${accepted_by}" ]]; then
    print -u2 "Worship proof requires a verified sermon manifest and the accepting operator's name."
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

  acceptance_plist="${phase_directory}/sermon-acceptance.plist"
  acceptance_json="${phase_directory}/sermon-acceptance.json"
  /usr/bin/plutil -create xml1 "${acceptance_plist}"
  /usr/bin/plutil -insert acceptedBy -string "${accepted_by}" "${acceptance_plist}"
  /usr/bin/plutil -insert acceptedAtUTC -string "${timestamp}" "${acceptance_plist}"
  /usr/bin/plutil -insert sermonManifest -string "${sermon_manifest}" "${acceptance_plist}"
  /usr/bin/plutil -insert decision -string "approved to begin supervised worship proof" "${acceptance_plist}"
  /usr/bin/plutil -convert json -o "${acceptance_json}" "${acceptance_plist}"
  /bin/rm "${acceptance_plist}"
fi

health_stop_file="${phase_directory}/.stop-health-monitor"
health_failure_file="${phase_directory}/.stream-health-failed"
health_log="${phase_directory}/stream-health-observations.tsv"
print -r -- $'timestampMs\tprobe\tstate\tdetail' > "${health_log}"

monitor_health_endpoint() {
  local probe_name="$1"
  local probe_url="$2"
  local consecutive_failures=0
  local response_file="${phase_directory}/.${probe_name}-health-response.json"

  while [[ ! -e "${health_stop_file}" ]]; do
    local now_ms="$(( $(date +%s) * 1000 ))"
    local state="healthy"
    local detail="fresh live payload"
    if ! /usr/bin/curl --silent --show-error --fail --max-time 3 \
      -H "Accept: application/json" \
      -o "${response_file}" \
      "${probe_url}"; then
      state="unhealthy"
      detail="HTTP request failed"
    else
      local healthy="$(/usr/bin/plutil -extract healthy raw -o - "${response_file}" 2>/dev/null || true)"
      local streaming="$(/usr/bin/plutil -extract streaming raw -o - "${response_file}" 2>/dev/null || true)"
      local audio_active="$(/usr/bin/plutil -extract audioActive raw -o - "${response_file}" 2>/dev/null || true)"
      local observed_ms="$(/usr/bin/plutil -extract timestampMs raw -o - "${response_file}" 2>/dev/null || true)"
      if [[ "${healthy}" != "true" || "${streaming}" != "true" || "${audio_active}" != "true" ||
            ! "${observed_ms}" =~ '^[0-9]+$' ]]; then
        state="unhealthy"
        detail="invalid or unhealthy JSON contract"
      else
        local age_ms="$(( now_ms - observed_ms ))"
        if (( age_ms < -5000 || age_ms > 15000 )); then
          state="unhealthy"
          detail="stale or future health timestamp"
        fi
      fi
    fi

    print -r -- "${now_ms}"$'\t'"${probe_name}"$'\t'"${state}"$'\t'"${detail}" >> "${health_log}"
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
  --output-dir "${phase_directory}"

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
print "${phase:u} hardware proof passed: ${manifest}"
