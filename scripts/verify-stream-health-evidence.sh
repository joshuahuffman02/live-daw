#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --stream-health PATH --manifest PATH"
  print -u2 "     [--expected-phase sermon|worship] [--require-production-duration]"
}

stream_health_path=""
manifest_path=""
expected_phase=""
require_production_duration=0

while (( $# > 0 )); do
  case "$1" in
    --stream-health) stream_health_path="${2:-}"; shift 2 ;;
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

if [[ -z "${stream_health_path}" || -z "${manifest_path}" ]]; then
  usage
  exit 2
fi
if [[ -n "${expected_phase}" &&
      "${expected_phase}" != "sermon" &&
      "${expected_phase}" != "worship" ]]; then
  print -u2 "Expected phase must be sermon or worship."
  exit 2
fi
if [[ ! -s "${stream_health_path}" || ! -s "${manifest_path}" ]]; then
  print -u2 "Stream-health log and full-check manifest must both be non-empty."
  exit 3
fi

extract_manifest() {
  /usr/bin/plutil -extract "$1" raw -o - "${manifest_path}" 2>/dev/null
}

scene="$(extract_manifest scene || true)"
hardware_passed="$(extract_manifest hardwareProofPassed || true)"
soundcheck_seconds="$(extract_manifest soundcheckSeconds || true)"
stability_seconds="$(extract_manifest stabilitySeconds || true)"
if [[ ( "${scene}" != "sermon" && "${scene}" != "worship" ) ||
      "${hardware_passed}" != "true" ||
      ! "${soundcheck_seconds}" =~ '^[0-9]+([.][0-9]+)?$' ||
      ! "${stability_seconds}" =~ '^[0-9]+([.][0-9]+)?$' ||
      ${soundcheck_seconds} -lt 1 ||
      ${stability_seconds} -lt 30 ]]; then
  print -u2 "Stream-health verification requires a passed hardware manifest with valid phase and durations."
  exit 4
fi
if [[ -n "${expected_phase}" && "${scene}" != "${expected_phase}" ]]; then
  print -u2 "Stream-health manifest phase mismatch: expected ${expected_phase}, observed ${scene}."
  exit 4
fi
if (( require_production_duration )) && (( stability_seconds < 7200 )); then
  print -u2 "Production stream-health proof requires at least 7,200 stability seconds."
  exit 4
fi

minimum_coverage_ms="$(( (soundcheck_seconds + stability_seconds) * 950.0 ))"
maximum_gap_ms=7000

if ! /usr/bin/awk \
    -F '\t' \
    -v minimum_coverage_ms="${minimum_coverage_ms}" \
    -v maximum_gap_ms="${maximum_gap_ms}" '
  function reject(message) {
    print "Stream-health evidence invalid: " message > "/dev/stderr"
    failed = 1
    exit 1
  }
  NR == 1 {
    expected = "checkedAtMs\tprobe\tstate\tresponseTimestampMs\tageMs\thealthy\tstreaming\taudioActive\tdetail"
    if ($0 != expected) reject("unexpected TSV header")
    next
  }
  {
    if (NF != 9) reject("row " NR " must contain exactly nine tab-separated fields")
    checked = $1
    probe = $2
    state = $3
    response = $4
    age = $5
    healthy = $6
    streaming = $7
    audio = $8
    detail = $9

    if (checked !~ /^[0-9]+$/ || checked < 1000000000000)
      reject("row " NR " has an invalid checkedAtMs")
    if (probe != "encoder" && probe != "egress")
      reject("row " NR " has an unknown probe")
    if (state != "healthy")
      reject(probe " row " NR " is not healthy")
    if (response !~ /^[0-9]+$/ || age !~ /^-?[0-9]+$/)
      reject(probe " row " NR " lacks response timestamp/age evidence")
    if (healthy != "true" || streaming != "true" || audio != "true")
      reject(probe " row " NR " does not prove healthy, streaming, and active audio")
    if (age < -5000 || age > 15000 || checked - response != age)
      reject(probe " row " NR " has stale, future, or inconsistent response time")
    if (detail == "")
      reject(probe " row " NR " has no detail")

    if (!(probe in count)) {
      first[probe] = checked
    } else {
      gap = checked - previous[probe]
      if (gap <= 0)
        reject(probe " timestamps are not strictly increasing")
      if (gap > maximum_gap_ms)
        reject(probe " observation gap exceeds " maximum_gap_ms " ms")
    }
    previous[probe] = checked
    last[probe] = checked
    count[probe]++
  }
  END {
    if (failed) exit 1
    for (probe_index = 1; probe_index <= 2; ++probe_index) {
      probe = probe_index == 1 ? "encoder" : "egress"
      if (count[probe] < 2) {
        print "Stream-health evidence invalid: " probe " has fewer than two observations" > "/dev/stderr"
        exit 1
      }
      coverage = last[probe] - first[probe]
      if (coverage < minimum_coverage_ms) {
        print "Stream-health evidence invalid: " probe " covers " coverage \
          " ms; requires at least " minimum_coverage_ms " ms" > "/dev/stderr"
        exit 1
      }
    }
  }
' "${stream_health_path}"; then
  exit 5
fi

print "Stream health verified: phase=${scene}, requested=$(( soundcheck_seconds + stability_seconds ))s, gap<=${maximum_gap_ms}ms, all encoder/egress observations healthy."
