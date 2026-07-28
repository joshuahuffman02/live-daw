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
  function is_local_host(value, host) {
    host = tolower(value)
    return host == "localhost" ||
      host ~ /^localhost[.]/ ||
      host ~ /[.]localhost$/ ||
      host ~ /^127[.]/ ||
      host == "0.0.0.0" ||
      host == "::" ||
      host == "0:0:0:0:0:0:0:0" ||
      host == "::1" ||
      host == "0:0:0:0:0:0:0:1" ||
      host ~ /^::ffff:127[.]/ ||
      host ~ /^0:0:0:0:0:ffff:127[.]/
  }
  NR == 1 {
    expected = "checkedAtMs\tprobe\tendpointPeer\tobserverKind\tformatVersion\tproductionEligible\tobserverIdentity\tsoftwareVersion\tplaybackHost\tmediaSequence\tdecodedAudioSamples\tauthenticated\tencoderProgressing\tencoderIntervalClean\tstate\tresponseTimestampMs\tageMs\thealthy\tstreaming\taudioActive\tdetail"
    if ($0 != expected) reject("unexpected TSV header")
    next
  }
  {
    if (NF != 21) reject("row " NR " must contain exactly 21 tab-separated fields")
    checked = $1
    probe = $2
    endpoint_peer = $3
    observer_kind = $4
    format_version = $5
    production_eligible = $6
    observer_identity = $7
    software_version = $8
    playback_host = $9
    media_sequence = $10
    decoded_audio_samples = $11
    authenticated = $12
    encoder_progressing = $13
    encoder_interval_clean = $14
    state = $15
    response = $16
    age = $17
    healthy = $18
    streaming = $19
    audio = $20
    detail = $21

    if (checked !~ /^[0-9]+$/ || checked < 1000000000000)
      reject("row " NR " has an invalid checkedAtMs")
    if (probe != "encoder" && probe != "egress")
      reject("row " NR " has an unknown probe")
    if (endpoint_peer == "" || length(endpoint_peer) > 128 ||
        endpoint_peer ~ /[[:space:][:cntrl:]]/)
      reject(probe " row " NR " has an invalid endpoint peer")
    if (format_version != "1" || production_eligible != "true")
      reject(probe " row " NR " is not production-eligible contract version 1")
    if (observer_identity !~ /[^[:space:]]/ || length(observer_identity) > 512 ||
        observer_identity ~ /[[:cntrl:]]/ ||
        software_version !~ /[^[:space:]]/ || length(software_version) > 512 ||
        software_version ~ /[[:cntrl:]]/)
      reject(probe " row " NR " lacks bounded observer identity/version evidence")
    if (state != "healthy")
      reject(probe " row " NR " is not healthy")
    if (response !~ /^[0-9]+$/ || age !~ /^-?[0-9]+$/)
      reject(probe " row " NR " lacks response timestamp/age evidence")
    if (healthy != "true" || streaming != "true" || audio != "true")
      reject(probe " row " NR " does not prove healthy, streaming, and active audio")
    if (age < -5000 || age > 15000 || checked - response != age)
      reject(probe " row " NR " has stale, future, or inconsistent response time")
    if (detail !~ /[^[:space:]]/ || length(detail) > 512 ||
        detail ~ /[[:cntrl:]]/)
      reject(probe " row " NR " has no detail")

    if (probe == "encoder") {
      if (observer_kind != "automix-obs-encoder-health")
        reject("encoder row " NR " has the wrong observer kind")
      if (endpoint_peer !~ /^127[.]/)
        reject("encoder row " NR " did not come from numeric loopback")
      if (playback_host != "-" || media_sequence != "-" ||
          decoded_audio_samples != "-")
        reject("encoder row " NR " has invalid public-egress sentinels")
      if (authenticated != "true" || encoder_progressing != "true" ||
          encoder_interval_clean != "true")
        reject("encoder row " NR " does not prove authenticated, clean encoder progress")
    } else {
      if (observer_kind != "automix-hls-egress-health")
        reject("egress row " NR " has the wrong observer kind")
      if (is_local_host(endpoint_peer))
        reject("egress row " NR " came from a local observer")
      if (authenticated != "-" || encoder_progressing != "-" ||
          encoder_interval_clean != "-")
        reject("egress row " NR " has invalid OBS sentinels")
      if (playback_host !~ /[^[:space:]]/ || length(playback_host) > 253 ||
          is_local_host(playback_host))
        reject("egress row " NR " lacks a remote playback host")
      if (media_sequence !~ /^[0-9]+$/ || media_sequence < 0)
        reject("egress row " NR " lacks a valid media sequence")
      if (decoded_audio_samples !~ /^[1-9][0-9]*$/)
        reject("egress row " NR " lacks decoded audio evidence")
      if (software_version !~ /^ffmpeg version /)
        reject("egress row " NR " lacks the exact FFmpeg observer version")
    }

    if (!(probe in count)) {
      first[probe] = checked
      first_response[probe] = response
      first_identity[probe] = observer_identity
      first_software[probe] = software_version
      if (probe == "egress") first_sequence[probe] = media_sequence
    } else {
      gap = checked - previous[probe]
      if (gap <= 0)
        reject(probe " timestamps are not strictly increasing")
      if (gap > maximum_gap_ms)
        reject(probe " observation gap exceeds " maximum_gap_ms " ms")
      if (response < previous_response[probe])
        reject(probe " response timestamps moved backward")
      if (observer_identity != first_identity[probe])
        reject(probe " observer identity changed during the proof")
      if (software_version != first_software[probe])
        reject(probe " observer software changed during the proof")
      if (probe == "egress" && media_sequence < previous_sequence[probe])
        reject("egress media sequence moved backward")
    }
    previous[probe] = checked
    previous_response[probe] = response
    if (probe == "egress") previous_sequence[probe] = media_sequence
    last[probe] = checked
    last_response[probe] = response
    if (probe == "egress") last_sequence[probe] = media_sequence
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
      if (last_response[probe] <= first_response[probe]) {
        print "Stream-health evidence invalid: " probe \
          " response timestamp never advanced" > "/dev/stderr"
        exit 1
      }
    }
    if (last_sequence["egress"] <= first_sequence["egress"]) {
      print "Stream-health evidence invalid: egress media sequence never advanced" \
        > "/dev/stderr"
      exit 1
    }
  }
' "${stream_health_path}"; then
  exit 5
fi

print "Stream health verified: phase=${scene}, requested=$(( soundcheck_seconds + stability_seconds ))s, gap<=${maximum_gap_ms}ms, provenance-bound encoder/egress observers remained healthy and advanced."
