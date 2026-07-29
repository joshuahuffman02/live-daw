#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 sermon APP_PATH INPUT_UID OUTPUT_UID PROFILE_PATH EVIDENCE_ROOT"
  print -u2 "  $0 worship APP_PATH INPUT_UID OUTPUT_UID PROFILE_PATH EVIDENCE_ROOT SERMON_MANIFEST SERMON_ACCEPTANCE_DIR TRUSTED_SIGNERS"
  print -u2 ""
  print -u2 "Production environment: HOST_READINESS_REPORT=/absolute/ready-report.json"
  print -u2 "Optional environment: STABILITY_SECONDS=7200 SOUNDCHECK_SECONDS=30 RECORDING_RESERVE_GB=20"
  print -u2 "Rehearsal-only environment: BUILD_METADATA=/absolute/release/build-metadata.json"
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
host_readiness_report="${HOST_READINESS_REPORT:-}"
build_metadata_path="${BUILD_METADATA:-}"
app_binary="${app_path}/Contents/MacOS/AutoMix Native"
signed_provenance="${app_path}/Contents/Resources/AutoMixReleaseProvenance.plist"
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
if [[ "${rehearsal_only}" != "1" && -z "${host_readiness_report}" ]]; then
  print -u2 "Production proof requires HOST_READINESS_REPORT from the fail-closed host audit."
  print -u2 "See docs/PRODUCTION_HOST_READINESS.md."
  exit 2
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
phase_directory="${evidence_root}/${phase}-${timestamp}"
/bin/mkdir -p "${phase_directory}"
app_signature_log="${phase_directory}/app-signature-verification.txt"
app_integrity_report="${phase_directory}/app-integrity.json"

# A rehearsal build can exercise every software check but cannot mint production
# hardware proof. Bind the evidence to an intact, notarized, Gatekeeper-accepted app.
: > "${app_signature_log}"
if ! /usr/bin/codesign --verify --deep --strict --verbose=2 \
    "${app_path}" >> "${app_signature_log}" 2>&1; then
  print -u2 "Hardware proof requires an intact signed app; inspect ${app_signature_log}."
  exit 3
fi
/usr/bin/codesign -dv --verbose=4 "${app_path}" >> "${app_signature_log}" 2>&1
if ! /usr/bin/xcrun stapler validate \
    "${app_path}" >> "${app_signature_log}" 2>&1; then
  print -u2 "Hardware proof requires a stapled notarization ticket; inspect ${app_signature_log}."
  exit 3
fi
if ! /usr/sbin/spctl --assess --type execute --verbose=4 \
    "${app_path}" >> "${app_signature_log}" 2>&1; then
  print -u2 "Hardware proof requires Gatekeeper acceptance; inspect ${app_signature_log}."
  exit 3
fi
app_binary_sha256="$(/usr/bin/shasum -a 256 "${app_binary}" | /usr/bin/awk '{print $1}')"
print -r -- "${app_binary_sha256}  ${app_binary}" >> "${app_signature_log}"

if [[ -n "${host_readiness_report}" ]]; then
  if [[ ! -f "${host_readiness_report}" || -L "${host_readiness_report}" ]]; then
    print -u2 "HOST_READINESS_REPORT must be a regular, non-symlink file."
    exit 3
  fi
  python_executable="$(command -v python3 2>/dev/null || true)"
  if [[ -z "${python_executable}" || "${python_executable}" != /* ||
        ! -x "${python_executable}" ]]; then
    print -u2 "An absolute executable python3 path is required to verify host readiness."
    exit 3
  fi
  "${python_executable}" -B \
    "${script_directory}/audit-production-host-readiness.py" \
    --verify-report "${host_readiness_report}"

  report_phase="$(/usr/bin/plutil -extract phase raw -o - "${host_readiness_report}")"
  report_app="$(/usr/bin/plutil -extract inputs.appPath raw -o - "${host_readiness_report}")"
  report_build_metadata="$(/usr/bin/plutil -extract inputs.buildMetadataPath raw -o - "${host_readiness_report}")"
  report_profile="$(/usr/bin/plutil -extract inputs.profilePath raw -o - "${host_readiness_report}")"
  report_inventory="$(/usr/bin/plutil -extract inputs.inventoryPath raw -o - "${host_readiness_report}")"
  report_failover_readiness="$(/usr/bin/plutil -extract inputs.failoverReadinessPath raw -o - "${host_readiness_report}")"
  report_recording_root="$(/usr/bin/plutil -extract inputs.recordingRoot raw -o - "${host_readiness_report}")"
  report_duration="$(/usr/bin/plutil -extract requirements.durationSeconds raw -o - "${host_readiness_report}")"
  report_reserve="$(/usr/bin/plutil -extract requirements.recordingReserveGiB raw -o - "${host_readiness_report}")"
  report_input_uid="$(/usr/bin/plutil -extract selectedInputUID raw -o - "${report_inventory}")"
  report_output_uid="$(/usr/bin/plutil -extract selectedOutputUID raw -o - "${report_inventory}")"

  if [[ "${report_phase}" != "${phase}" ||
        "${report_app:A}" != "${app_path:A}" ||
        "${report_profile:A}" != "${profile_path:A}" ||
        "${report_input_uid}" != "${input_uid}" ||
        "${report_output_uid}" != "${output_uid}" ]]; then
    print -u2 "Host readiness is bound to a different phase, app, profile, or Core Audio route."
    exit 3
  fi
  if [[ -n "${build_metadata_path}" &&
        "${build_metadata_path:A}" != "${report_build_metadata:A}" ]]; then
    print -u2 "BUILD_METADATA does not match the release metadata bound by host readiness."
    exit 3
  fi
  build_metadata_path="${report_build_metadata}"
  if (( report_duration < stability_seconds || report_reserve < recording_reserve_gb )); then
    print -u2 "Host readiness duration/reserve is smaller than this proof request."
    exit 3
  fi
  if [[ ! -d "${report_recording_root}" ||
        "$(/usr/bin/stat -f %d "${report_recording_root}")" !=
          "$(/usr/bin/stat -f %d "${phase_directory}")" ]]; then
    print -u2 "Host readiness recording capacity was measured on a different volume."
    exit 3
  fi

  readiness_copy="${phase_directory}/production-host-readiness.json"
  /bin/cp "${host_readiness_report}" "${readiness_copy}"
  /bin/chmod 600 "${readiness_copy}"
  /usr/bin/shasum -a 256 "${readiness_copy}" > "${readiness_copy}.sha256"
  /bin/chmod 600 "${readiness_copy}.sha256"
  failover_readiness_copy="${phase_directory}/external-failover-controller-readiness.json"
  /bin/cp "${report_failover_readiness}" "${failover_readiness_copy}"
  /bin/chmod 600 "${failover_readiness_copy}"
  /usr/bin/shasum -a 256 "${failover_readiness_copy}" > "${failover_readiness_copy}.sha256"
  /bin/chmod 600 "${failover_readiness_copy}.sha256"
elif [[ "${rehearsal_only}" == "1" ]]; then
  print -u2 "WARNING: rehearsal is running without a production host-readiness report."
fi

if [[ -z "${build_metadata_path}" ||
      ! -f "${build_metadata_path}" ||
      -L "${build_metadata_path}" ||
      ! -f "${signed_provenance}" ||
      -L "${signed_provenance}" ]]; then
  print -u2 "The untouched release build-metadata.json and signed provenance resource are required."
  print -u2 "For rehearsal-only runs, set BUILD_METADATA to the release metadata path."
  exit 3
fi

metadata_kind="$(/usr/bin/plutil -extract kind raw -o - "${build_metadata_path}" 2>/dev/null || true)"
metadata_format="$(/usr/bin/plutil -extract formatVersion raw -o - "${build_metadata_path}" 2>/dev/null || true)"
metadata_commit="$(/usr/bin/plutil -extract commit raw -o - "${build_metadata_path}" 2>/dev/null || true)"
metadata_binary_sha="$(/usr/bin/plutil -extract appBinarySHA256 raw -o - "${build_metadata_path}" 2>/dev/null || true)"
metadata_provenance_sha="$(/usr/bin/plutil -extract signedProvenanceSHA256 raw -o - "${build_metadata_path}" 2>/dev/null || true)"
provenance_kind="$(/usr/bin/plutil -extract kind raw -o - "${signed_provenance}" 2>/dev/null || true)"
provenance_format="$(/usr/bin/plutil -extract formatVersion raw -o - "${signed_provenance}" 2>/dev/null || true)"
provenance_commit="$(/usr/bin/plutil -extract sourceCommit raw -o - "${signed_provenance}" 2>/dev/null || true)"
signed_provenance_sha256="$(/usr/bin/shasum -a 256 "${signed_provenance}" | /usr/bin/awk '{print $1}')"
if [[ "${metadata_kind}" != "automix-native-release-build" ||
      "${metadata_format}" != "1" ||
      "${provenance_kind}" != "automix-native-signed-provenance" ||
      "${provenance_format}" != "1" ||
      ! "${metadata_commit}" =~ '^[0-9a-f]{40}$' ||
      "${metadata_commit}" != "${provenance_commit}" ||
      "${metadata_binary_sha}" != "${app_binary_sha256}" ||
      "${metadata_provenance_sha}" != "${signed_provenance_sha256}" ]]; then
  print -u2 "Release metadata, signed provenance, and the staged app do not describe the same build."
  exit 3
fi

build_metadata_copy="${phase_directory}/build-metadata.json"
/bin/cp "${build_metadata_path}" "${build_metadata_copy}"
/bin/chmod 600 "${build_metadata_copy}"
build_metadata_sha256="$(/usr/bin/shasum -a 256 "${build_metadata_copy}" | /usr/bin/awk '{print $1}')"
signature_log_sha256="$(/usr/bin/shasum -a 256 "${app_signature_log}" | /usr/bin/awk '{print $1}')"
integrity_plist="${phase_directory}/.app-integrity.plist"
/usr/bin/plutil -create xml1 "${integrity_plist}"
/usr/bin/plutil -insert formatVersion -integer 1 "${integrity_plist}"
/usr/bin/plutil -insert kind -string automix-app-integrity "${integrity_plist}"
/usr/bin/plutil -insert sourceCommit -string "${metadata_commit}" "${integrity_plist}"
/usr/bin/plutil -insert appBinarySHA256 -string "${app_binary_sha256}" "${integrity_plist}"
/usr/bin/plutil -insert signedProvenanceSHA256 -string "${signed_provenance_sha256}" "${integrity_plist}"
/usr/bin/plutil -insert buildMetadataSHA256 -string "${build_metadata_sha256}" "${integrity_plist}"
/usr/bin/plutil -insert signatureVerificationLogPath -string "${app_signature_log:A}" "${integrity_plist}"
/usr/bin/plutil -insert signatureVerificationLogSHA256 -string "${signature_log_sha256}" "${integrity_plist}"
/usr/bin/plutil -insert signatureVerified -bool true "${integrity_plist}"
/usr/bin/plutil -insert notarizationStapled -bool true "${integrity_plist}"
/usr/bin/plutil -insert gatekeeperAccepted -bool true "${integrity_plist}"
/usr/bin/plutil -insert checkedAtUTC -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${integrity_plist}"
/usr/bin/plutil -convert json -o "${app_integrity_report}" "${integrity_plist}"
/bin/chmod 600 "${app_integrity_report}"
/bin/rm "${integrity_plist}"

encoder_health_url="$(/usr/bin/plutil -extract encoderHealthURL raw -o - "${profile_path}" 2>/dev/null || true)"
egress_health_url="$(/usr/bin/plutil -extract egressHealthURL raw -o - "${profile_path}" 2>/dev/null || true)"
if [[ -z "${encoder_health_url}" || -z "${egress_health_url}" ]]; then
  print -u2 "Both encoderHealthURL and egressHealthURL must be configured in the venue profile."
  exit 3
fi

is_local_health_host() {
  local host="${1:l}"
  local local_address
  for local_address in "${local_health_addresses[@]}"; do
    if [[ "${host}" == "${local_address}" ]]; then
      return 0
    fi
  done
  [[ "${host}" == "localhost" ||
     "${host}" == localhost.* ||
     "${host}" == *.localhost ||
     "${host}" == 127.* ||
     "${host}" == "0.0.0.0" ||
     "${host}" == "::" ||
     "${host}" == "0:0:0:0:0:0:0:0" ||
     "${host}" == "::1" ||
     "${host}" == "0:0:0:0:0:0:0:1" ||
     "${host}" == ::ffff:127.* ||
     "${host}" == 0:0:0:0:0:ffff:127.* ]]
}

typeset -a local_health_addresses
local_health_addresses=(
  "${(@f)$(/sbin/ifconfig -a | /usr/bin/awk '
    /^[[:space:]]*inet / {
      print tolower($2)
    }
    /^[[:space:]]*inet6 / {
      sub(/%.*/, "", $2)
      print tolower($2)
    }
  ')}"
)

validate_health_endpoint_url() {
  local role="$1"
  local url="$2"
  if [[ ( "${url}" != http://* && "${url}" != https://* ) ||
        "${url}" == *[[:cntrl:]]* ||
        "${url}" == *"@"* ||
        "${url}" == *"?"* ||
        "${url}" == *"#"* ]]; then
    print -u2 "${role} health URL must be a token-free HTTP(S) URL."
    return 1
  fi
  local remainder="${url#*://}"
  local authority="${remainder%%/*}"
  local authority_host="${authority%%:*}"
  if [[ "${authority}" == \[*\]* ]]; then
    authority_host="${authority#\[}"
    authority_host="${authority_host%%\]*}"
  fi
  local path="/${remainder#*/}"
  if [[ -z "${authority}" || "${path}" != "/health" ]]; then
    print -u2 "${role} health URL must target the exact /health path."
    return 1
  fi
  if [[ "${role}" == "encoder" ]]; then
    if [[ "${authority}" != "127.0.0.1" &&
          "${authority}" != 127.0.0.1:* ]]; then
      print -u2 "Encoder health must use the local numeric loopback bridge."
      return 1
    fi
  elif is_local_health_host "${authority_host}"; then
    print -u2 "Public egress health must use a remote observer endpoint."
    return 1
  fi
}

validate_health_endpoint_url "encoder" "${encoder_health_url}" || exit 3
validate_health_endpoint_url "egress" "${egress_health_url}" || exit 3

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
print -r -- $'checkedAtMs\tprobe\tendpointPeer\tobserverKind\tformatVersion\tproductionEligible\tobserverIdentity\tsoftwareVersion\tplaybackHost\tmediaSequence\tdecodedAudioSamples\tauthenticated\tencoderProgressing\tencoderIntervalClean\tstate\tresponseTimestampMs\tageMs\thealthy\tstreaming\taudioActive\tdetail' > "${health_log}"

valid_health_text() {
  local value="$1"
  local maximum="${2:-512}"
  [[ -n "${value}" &&
     ${#value} -le ${maximum} &&
     "${value}" != *[[:cntrl:]]* ]]
}

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
    local endpoint_peer=""
    local observer_kind=""
    local format_version=""
    local production_eligible=""
    local observer_identity="-"
    local software_version="-"
    local playback_host="-"
    local media_sequence="-"
    local decoded_audio_samples="-"
    local authenticated="-"
    local encoder_progressing="-"
    local encoder_interval_clean="-"
    if ! endpoint_peer="$(/usr/bin/curl --silent --show-error --fail --max-time 3 \
      --max-filesize 65536 \
      -H "Accept: application/json" \
      -o "${response_file}" \
      --write-out '%{remote_ip}' \
      "${probe_url}")"; then
      state="unhealthy"
      detail="HTTP request failed"
    else
      observer_kind="$(/usr/bin/plutil -extract kind raw -o - "${response_file}" 2>/dev/null || true)"
      format_version="$(/usr/bin/plutil -extract formatVersion raw -o - "${response_file}" 2>/dev/null || true)"
      production_eligible="$(/usr/bin/plutil -extract productionEligible raw -o - "${response_file}" 2>/dev/null || true)"
      healthy="$(/usr/bin/plutil -extract healthy raw -o - "${response_file}" 2>/dev/null || true)"
      streaming="$(/usr/bin/plutil -extract streaming raw -o - "${response_file}" 2>/dev/null || true)"
      audio_active="$(/usr/bin/plutil -extract audioActive raw -o - "${response_file}" 2>/dev/null || true)"
      observed_ms="$(/usr/bin/plutil -extract timestampMs raw -o - "${response_file}" 2>/dev/null || true)"
      detail="$(/usr/bin/plutil -extract detail raw -o - "${response_file}" 2>/dev/null || true)"
      if [[ "${probe_name}" == "encoder" ]]; then
        observer_identity="$(/usr/bin/plutil -extract audioInput raw -o - "${response_file}" 2>/dev/null || true)"
        software_version="$(/usr/bin/plutil -extract obsStudioVersion raw -o - "${response_file}" 2>/dev/null || true)"
        authenticated="$(/usr/bin/plutil -extract authenticated raw -o - "${response_file}" 2>/dev/null || true)"
        encoder_progressing="$(/usr/bin/plutil -extract encoderProgressing raw -o - "${response_file}" 2>/dev/null || true)"
        encoder_interval_clean="$(/usr/bin/plutil -extract encoderIntervalClean raw -o - "${response_file}" 2>/dev/null || true)"
      else
        observer_identity="$(/usr/bin/plutil -extract observerSite raw -o - "${response_file}" 2>/dev/null || true)"
        software_version="$(/usr/bin/plutil -extract ffmpegVersion raw -o - "${response_file}" 2>/dev/null || true)"
        playback_host="$(/usr/bin/plutil -extract playbackHost raw -o - "${response_file}" 2>/dev/null || true)"
        media_sequence="$(/usr/bin/plutil -extract mediaSequence raw -o - "${response_file}" 2>/dev/null || true)"
        decoded_audio_samples="$(/usr/bin/plutil -extract decodedAudioSamples raw -o - "${response_file}" 2>/dev/null || true)"
      fi
      if [[ "${healthy}" != "true" ||
            "${streaming}" != "true" ||
            "${audio_active}" != "true" ||
            "${format_version}" != "1" ||
            "${production_eligible}" != "true" ||
            ! "${observed_ms}" =~ '^[0-9]+$' ]]; then
        state="unhealthy"
        detail="invalid or unhealthy JSON contract"
      elif ! valid_health_text "${endpoint_peer}" 128 ||
           ! valid_health_text "${observer_identity}" 512 ||
           ! valid_health_text "${software_version}" 512 ||
           ! valid_health_text "${detail}" 512; then
        state="unhealthy"
        detail="invalid observer provenance text"
      elif [[ "${probe_name}" == "encoder" &&
              ( "${observer_kind}" != "automix-obs-encoder-health" ||
                "${endpoint_peer}" != 127.* ||
                "${authenticated}" != "true" ||
                "${encoder_progressing}" != "true" ||
                "${encoder_interval_clean}" != "true" ) ]]; then
        state="unhealthy"
        detail="wrong or rehearsal-only OBS observer"
      elif [[ "${probe_name}" == "egress" &&
              ( "${observer_kind}" != "automix-hls-egress-health" ||
                ! "${media_sequence}" =~ '^[0-9]+$' ||
                ! "${decoded_audio_samples}" =~ '^[1-9][0-9]*$' ||
                "${software_version}" != "ffmpeg version "* ) ]]; then
        state="unhealthy"
        detail="wrong, local, or incomplete public-egress observer"
      elif [[ "${probe_name}" == "egress" ]] &&
           is_local_health_host "${endpoint_peer}"; then
        state="unhealthy"
        detail="public-egress observer resolved to this host"
      elif [[ "${probe_name}" == "egress" ]] &&
           ( ! valid_health_text "${playback_host}" 253 ||
             is_local_health_host "${playback_host}" ); then
        state="unhealthy"
        detail="public playback hostname is missing or local"
      else
        age_ms="$(( now_ms - observed_ms ))"
        if (( age_ms < -5000 || age_ms > 15000 )); then
          state="unhealthy"
          detail="stale or future health timestamp"
        fi
      fi
    fi

    print -r -- "${now_ms}"$'\t'"${probe_name}"$'\t'"${endpoint_peer}"$'\t'"${observer_kind}"$'\t'"${format_version}"$'\t'"${production_eligible}"$'\t'"${observer_identity}"$'\t'"${software_version}"$'\t'"${playback_host}"$'\t'"${media_sequence}"$'\t'"${decoded_audio_samples}"$'\t'"${authenticated}"$'\t'"${encoder_progressing}"$'\t'"${encoder_interval_clean}"$'\t'"${state}"$'\t'"${observed_ms}"$'\t'"${age_ms}"$'\t'"${healthy}"$'\t'"${streaming}"$'\t'"${audio_active}"$'\t'"${detail}" >> "${health_log}"
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
