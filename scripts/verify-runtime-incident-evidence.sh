#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --report PATH --manifest PATH"
  print -u2 "     [--expected-phase sermon|worship] [--require-production-duration]"
}

report_path=""
manifest_path=""
expected_phase=""
require_production_duration=0

while (( $# > 0 )); do
  case "$1" in
    --report) report_path="${2:-}"; shift 2 ;;
    --manifest) manifest_path="${2:-}"; shift 2 ;;
    --expected-phase) expected_phase="${2:-}"; shift 2 ;;
    --require-production-duration) require_production_duration=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      print -u2 "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${report_path}" || -z "${manifest_path}" ]]; then
  usage
  exit 2
fi
if [[ -n "${expected_phase}" &&
      "${expected_phase}" != "sermon" &&
      "${expected_phase}" != "worship" ]]; then
  print -u2 "Expected phase must be sermon or worship."
  exit 2
fi
if [[ ! -s "${report_path}" || ! -s "${manifest_path}" ]]; then
  print -u2 "Runtime-incident report and full-check manifest must both be non-empty."
  exit 3
fi

extract() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

fail() {
  print -u2 "Runtime-incident evidence invalid: $*"
  exit 5
}

format_version="$(extract "${report_path}" formatVersion || true)"
proof_type="$(extract "${report_path}" proofType || true)"
phase="$(extract "${report_path}" phase || true)"
manifest_sha="$(extract "${report_path}" fullCheckManifestSHA256 || true)"
window_start_ms="$(extract "${report_path}" windowStartedAtMs || true)"
window_end_ms="$(extract "${report_path}" windowEndedAtMs || true)"
captured_at_ms="$(extract "${report_path}" capturedAtMs || true)"
source_present="$(extract "${report_path}" sourceJournalPresent || true)"
source_path="$(extract "${report_path}" sourceJournalPath || true)"
source_sha="$(extract "${report_path}" sourceJournalSHA256 || true)"
source_bytes="$(extract "${report_path}" sourceJournalBytes || true)"
source_lines="$(extract "${report_path}" sourceLineCount || true)"
incident_count="$(extract "${report_path}" incidents || true)"
reported_info="$(extract "${report_path}" infoCount || true)"
reported_warning="$(extract "${report_path}" warningCount || true)"
reported_critical="$(extract "${report_path}" criticalCount || true)"
reported_passed="$(extract "${report_path}" passed || true)"

if [[ "${format_version}" != "1" ||
      "${proof_type}" != "runtime-incidents" ||
      ( "${phase}" != "sermon" && "${phase}" != "worship" ) ||
      ! "${manifest_sha}" =~ '^[0-9a-f]{64}$' ||
      ! "${window_start_ms}" =~ '^[0-9]+$' ||
      ! "${window_end_ms}" =~ '^[0-9]+$' ||
      ! "${captured_at_ms}" =~ '^[0-9]+$' ||
      ! "${source_bytes}" =~ '^[0-9]+$' ||
      ! "${source_lines}" =~ '^[0-9]+$' ||
      ! "${incident_count}" =~ '^[0-9]+$' ||
      ! "${reported_info}" =~ '^[0-9]+$' ||
      ! "${reported_warning}" =~ '^[0-9]+$' ||
      ! "${reported_critical}" =~ '^[0-9]+$' ||
      ( "${source_present}" != "true" && "${source_present}" != "false" ) ||
      ( "${reported_passed}" != "true" && "${reported_passed}" != "false" ) ]]; then
  fail "report metadata is incomplete or malformed."
fi
if [[ -n "${expected_phase}" && "${phase}" != "${expected_phase}" ]]; then
  fail "report phase ${phase} does not match selected phase ${expected_phase}."
fi
if (( window_end_ms <= window_start_ms || captured_at_ms < window_end_ms )); then
  fail "capture/window timestamps are not ordered."
fi
if [[ "${source_present}" == "true" ]]; then
  if [[ "${source_path}" != /* || ! "${source_sha}" =~ '^[0-9a-f]{64}$' ]]; then
    fail "present source journal must have an absolute path and SHA-256."
  fi
else
  if [[ -n "${source_sha}" || source_bytes -ne 0 || source_lines -ne 0 ]]; then
    fail "absent source journal must have empty hash and zero bytes/lines."
  fi
fi
if (( source_lines < incident_count )); then
  fail "window incident count exceeds the captured source line count."
fi

observed_manifest_sha="$(/usr/bin/shasum -a 256 "${manifest_path}" | /usr/bin/awk '{print $1}')"
if [[ "${manifest_sha}" != "${observed_manifest_sha}" ]]; then
  fail "report is bound to a different full-check manifest."
fi
manifest_phase="$(extract "${manifest_path}" scene || true)"
manifest_hardware="$(extract "${manifest_path}" hardwareProofPassed || true)"
soundcheck_seconds="$(extract "${manifest_path}" soundcheckSeconds || true)"
stability_seconds="$(extract "${manifest_path}" stabilitySeconds || true)"
if [[ "${manifest_phase}" != "${phase}" ||
      "${manifest_hardware}" != "true" ||
      ! "${soundcheck_seconds}" =~ '^[0-9]+([.][0-9]+)?$' ||
      ! "${stability_seconds}" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  fail "selected manifest is not matching, passed hardware proof."
fi
if (( require_production_duration )) && (( stability_seconds < 7200 )); then
  fail "production incident proof requires at least 7,200 stability seconds."
fi
minimum_window_ms="$(( (soundcheck_seconds + stability_seconds) * 950.0 ))"
if (( window_end_ms - window_start_ms < minimum_window_ms )); then
  fail "incident window does not cover at least 95% of the requested proof duration."
fi

integer info_count=0
integer warning_count=0
integer critical_count=0
integer index=0
previous_timestamp=0
while (( index < incident_count )); do
  prefix="incidents.${index}"
  timestamp="$(extract "${report_path}" "${prefix}.timestampMs" || true)"
  kind="$(extract "${report_path}" "${prefix}.kind" || true)"
  severity="$(extract "${report_path}" "${prefix}.severity" || true)"
  message="$(extract "${report_path}" "${prefix}.message" || true)"
  details_xml="$(/usr/bin/plutil -extract "${prefix}.details" xml1 -o - "${report_path}" 2>/dev/null || true)"
  if [[ ! "${timestamp}" =~ '^[0-9]+$' ||
        ! "${kind}" =~ '^[A-Za-z0-9._-]{1,128}$' ||
        ( "${severity}" != "info" && "${severity}" != "warning" && "${severity}" != "critical" ) ||
        -z "${message}" ||
        "${message}" == *[[:cntrl:]]* ||
        ${#message} -gt 1000 ||
        "${details_xml}" != *"<dict>"* ]]; then
    fail "incident ${index} is malformed."
  fi
  if (( timestamp < window_start_ms || timestamp > window_end_ms )); then
    fail "incident ${index} lies outside the declared proof window."
  fi
  if (( index > 0 && timestamp < previous_timestamp )); then
    fail "incidents are not timestamp ordered."
  fi
  previous_timestamp="${timestamp}"
  case "${severity}" in
    info) info_count="$(( info_count + 1 ))" ;;
    warning) warning_count="$(( warning_count + 1 ))" ;;
    critical) critical_count="$(( critical_count + 1 ))" ;;
  esac
  index="$(( index + 1 ))"
done

if (( info_count != reported_info ||
      warning_count != reported_warning ||
      critical_count != reported_critical )); then
  fail "reported severity totals do not match the incident array."
fi
if (( warning_count > 0 || critical_count > 0 )) || [[ "${reported_passed}" != "true" ]]; then
  fail "promotion requires zero warning and zero critical incidents in the proof window."
fi

print "Runtime incidents verified: phase=${phase}, info=${info_count}, warning=0, critical=0, sourceLines=${source_lines}."
