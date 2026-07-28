#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --journal PATH --manifest PATH --phase sermon|worship"
  print -u2 "     --window-start-ms INTEGER --window-end-ms INTEGER --output PATH"
  print -u2 "     [--require-production-duration] [--replace]"
}

journal_path=""
manifest_path=""
phase=""
window_start_ms=""
window_end_ms=""
output_path=""
require_production_duration=0
replace_existing=0

while (( $# > 0 )); do
  case "$1" in
    --journal) journal_path="${2:-}"; shift 2 ;;
    --manifest) manifest_path="${2:-}"; shift 2 ;;
    --phase) phase="${2:-}"; shift 2 ;;
    --window-start-ms) window_start_ms="${2:-}"; shift 2 ;;
    --window-end-ms) window_end_ms="${2:-}"; shift 2 ;;
    --output) output_path="${2:-}"; shift 2 ;;
    --require-production-duration) require_production_duration=1; shift ;;
    --replace) replace_existing=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      print -u2 "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${journal_path}" ||
      -z "${manifest_path}" ||
      -z "${output_path}" ||
      ( "${phase}" != "sermon" && "${phase}" != "worship" ) ||
      ! "${window_start_ms}" =~ '^[0-9]+$' ||
      ! "${window_end_ms}" =~ '^[0-9]+$' ||
      ${window_end_ms} -le ${window_start_ms} ||
      ! -s "${manifest_path}" ]]; then
  usage
  exit 2
fi

output_directory="${output_path:h}"
/bin/mkdir -p "${output_directory}"
output_directory="$(/bin/realpath "${output_directory}")"
output_path="${output_directory}/${output_path:t}"
if [[ -e "${output_path}" ]] && (( ! replace_existing )); then
  print -u2 "Runtime incident evidence already exists; pass --replace to overwrite it: ${output_path}"
  exit 3
fi
report_plist="$(/usr/bin/mktemp "${output_directory}/.runtime-incident-evidence.XXXXXX")"
line_file="$(/usr/bin/mktemp "${output_directory}/.runtime-incident-line.XXXXXX")"
report_json="$(/usr/bin/mktemp "${output_directory}/.runtime-incident-evidence-json.XXXXXX")"
cleanup() {
  /bin/rm -f "${report_plist}" "${line_file}" "${report_json}"
}
trap cleanup EXIT INT TERM

/usr/bin/plutil -create xml1 "${report_plist}"
/usr/bin/plutil -insert formatVersion -integer 1 "${report_plist}"
/usr/bin/plutil -insert proofType -string runtime-incidents "${report_plist}"
/usr/bin/plutil -insert phase -string "${phase}" "${report_plist}"
/usr/bin/plutil -insert fullCheckManifestSHA256 -string \
  "$(/usr/bin/shasum -a 256 "${manifest_path}" | /usr/bin/awk '{print $1}')" \
  "${report_plist}"
/usr/bin/plutil -insert windowStartedAtMs -integer "${window_start_ms}" "${report_plist}"
/usr/bin/plutil -insert windowEndedAtMs -integer "${window_end_ms}" "${report_plist}"
/usr/bin/plutil -insert capturedAtMs -integer "$(( $(date +%s) * 1000 ))" "${report_plist}"
/usr/bin/plutil -insert sourceJournalPath -string "${journal_path:A}" "${report_plist}"
/usr/bin/plutil -insert incidents -json '[]' "${report_plist}"

source_present=false
source_sha=""
source_bytes=0
integer source_lines=0
integer incident_index=0
integer info_count=0
integer warning_count=0
integer critical_count=0
previous_timestamp=0

if [[ -f "${journal_path}" ]]; then
  source_present=true
  source_sha="$(/usr/bin/shasum -a 256 "${journal_path}" | /usr/bin/awk '{print $1}')"
  source_bytes="$(/usr/bin/stat -f '%z' "${journal_path}")"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    source_lines="$(( source_lines + 1 ))"
    if [[ -z "${line}" ]]; then
      print -u2 "Runtime incident journal contains a blank line at ${source_lines}."
      exit 4
    fi
    print -r -- "${line}" > "${line_file}"
    timestamp="$(/usr/bin/plutil -extract timestampMs raw -o - "${line_file}" 2>/dev/null || true)"
    kind="$(/usr/bin/plutil -extract kind raw -o - "${line_file}" 2>/dev/null || true)"
    severity="$(/usr/bin/plutil -extract severity raw -o - "${line_file}" 2>/dev/null || true)"
    message="$(/usr/bin/plutil -extract message raw -o - "${line_file}" 2>/dev/null || true)"
    details_xml="$(/usr/bin/plutil -extract details xml1 -o - "${line_file}" 2>/dev/null || true)"
    if [[ ! "${timestamp}" =~ '^[0-9]+$' ||
          ! "${kind}" =~ '^[A-Za-z0-9._-]{1,128}$' ||
          ( "${severity}" != "info" && "${severity}" != "warning" && "${severity}" != "critical" ) ||
          -z "${message}" ||
          "${message}" == *[[:cntrl:]]* ||
          "${details_xml}" != *"<dict>"* ]]; then
      print -u2 "Runtime incident journal line ${source_lines} is malformed."
      exit 4
    fi
    if (( timestamp >= window_start_ms && timestamp <= window_end_ms )); then
      if (( incident_index > 0 && timestamp < previous_timestamp )); then
        print -u2 "Proof-window incident timestamps are not ordered at source line ${source_lines}."
        exit 4
      fi
      previous_timestamp="${timestamp}"
      /usr/bin/plutil -insert "incidents.${incident_index}" -json "${line}" "${report_plist}"
      case "${severity}" in
        info) info_count="$(( info_count + 1 ))" ;;
        warning) warning_count="$(( warning_count + 1 ))" ;;
        critical) critical_count="$(( critical_count + 1 ))" ;;
      esac
      incident_index="$(( incident_index + 1 ))"
    fi
  done < "${journal_path}"
fi

/usr/bin/plutil -insert sourceJournalPresent -bool "${source_present}" "${report_plist}"
/usr/bin/plutil -insert sourceJournalSHA256 -string "${source_sha}" "${report_plist}"
/usr/bin/plutil -insert sourceJournalBytes -integer "${source_bytes}" "${report_plist}"
/usr/bin/plutil -insert sourceLineCount -integer "${source_lines}" "${report_plist}"
/usr/bin/plutil -insert infoCount -integer "${info_count}" "${report_plist}"
/usr/bin/plutil -insert warningCount -integer "${warning_count}" "${report_plist}"
/usr/bin/plutil -insert criticalCount -integer "${critical_count}" "${report_plist}"
if (( warning_count == 0 && critical_count == 0 )); then
  /usr/bin/plutil -insert passed -bool true "${report_plist}"
else
  /usr/bin/plutil -insert passed -bool false "${report_plist}"
fi
/usr/bin/plutil -convert json -o "${report_json}" "${report_plist}"
/bin/mv -f "${report_json}" "${output_path}"

verify_arguments=(
  --report "${output_path}"
  --manifest "${manifest_path}"
  --expected-phase "${phase}"
)
if (( require_production_duration )); then
  verify_arguments+=(--require-production-duration)
fi
"${0:A:h}/verify-runtime-incident-evidence.sh" "${verify_arguments[@]}"
print "Recorded runtime incident evidence: ${output_path}"
