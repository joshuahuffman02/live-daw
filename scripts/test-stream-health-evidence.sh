#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
fixture_root="$(/usr/bin/mktemp -d /tmp/live-daw-stream-health-test.XXXXXX)"
cleanup() {
  if [[ "${fixture_root}" == /tmp/live-daw-stream-health-test.* && -d "${fixture_root}" ]]; then
    /bin/rm -rf "${fixture_root}"
  fi
}
trap cleanup EXIT INT TERM

manifest="${fixture_root}/manifest.json"
health_log="${fixture_root}/stream-health.tsv"
/usr/bin/plutil -create xml1 "${manifest}"
/usr/bin/plutil -insert scene -string sermon "${manifest}"
/usr/bin/plutil -insert hardwareProofPassed -bool true "${manifest}"
/usr/bin/plutil -insert soundcheckSeconds -float 30.0 "${manifest}"
/usr/bin/plutil -insert stabilitySeconds -float 300.0 "${manifest}"
/usr/bin/plutil -convert json "${manifest}"

write_fixture() {
  local output="$1"
  local stop_ms="${2:-330000}"
  local freeze_sequence="${3:-0}"
  /usr/bin/awk -v stop_ms="${stop_ms}" -v freeze_sequence="${freeze_sequence}" 'BEGIN {
    print "checkedAtMs\tprobe\tendpointPeer\tobserverKind\tformatVersion\tproductionEligible\tobserverIdentity\tsoftwareVersion\tplaybackHost\tmediaSequence\tdecodedAudioSamples\tauthenticated\tencoderProgressing\tencoderIntervalClean\tstate\tresponseTimestampMs\tageMs\thealthy\tstreaming\taudioActive\tdetail"
    base = 1780000000000
    for (offset = 0; offset <= stop_ms; offset += 2000) {
      checked = base + offset
      response = checked - 1000
      sequence = freeze_sequence ? 100 : 100 + int(offset / 4000)
      print checked \
        "\tencoder\t127.0.0.1\tautomix-obs-encoder-health\t1\ttrue" \
        "\tAutoMix Program\t32.2.1\t-\t-\t-\ttrue\ttrue\ttrue\thealthy\t" \
        response "\t1000\ttrue\ttrue\ttrue\tfresh live payload"
      print checked \
        "\tegress\t10.88.0.2\tautomix-hls-egress-health\t1\ttrue" \
        "\toffsite-cellular\tffmpeg version fixture\tcdn.example.test\t" \
        sequence "\t1024\t-\t-\t-\thealthy\t" response \
        "\t1000\ttrue\ttrue\ttrue\tfresh live payload"
    }
  }' > "${output}"
}

verify() {
  "${script_directory}/verify-stream-health-evidence.sh" \
    --stream-health "${health_log}" \
    --manifest "${manifest}" \
    --expected-phase sermon
}

expect_rejection() {
  local label="$1"
  if verify >/dev/null 2>&1; then
    print -u2 "Stream-health verifier accepted ${label}."
    exit 1
  fi
}

write_fixture "${health_log}"
verify >/dev/null

/usr/bin/sed -i '' '2s/\thealthy\t/\tunhealthy\t/' "${health_log}"
expect_rejection "an unhealthy encoder observation"
write_fixture "${health_log}"

/usr/bin/sed -i '' '4s/\t1000\ttrue\ttrue\ttrue\tfresh live payload$/\t16000\ttrue\ttrue\ttrue\tfresh live payload/' "${health_log}"
expect_rejection "a stale endpoint timestamp"
write_fixture "${health_log}"

/usr/bin/sed -i '' '5,10d' "${health_log}"
expect_rejection "an observation gap above seven seconds"
write_fixture "${health_log}"

/usr/bin/sed -i '' '2s/automix-obs-encoder-health/generic-health/' "${health_log}"
expect_rejection "a generic endpoint impersonating encoder health"
write_fixture "${health_log}"

/usr/bin/sed -i '' '3s/\tautomix-hls-egress-health\t1\ttrue\t/\tautomix-hls-egress-health\t1\tfalse\t/' "${health_log}"
expect_rejection "a rehearsal-only egress observer"
write_fixture "${health_log}"

/usr/bin/sed -i '' '3s/\tegress\t10.88.0.2\t/\tegress\t127.0.0.1\t/' "${health_log}"
expect_rejection "a local process impersonating public egress"
write_fixture "${health_log}"

/usr/bin/sed -i '' '3s/\tegress\t10.88.0.2\t/\tegress\t::ffff:127.0.0.1\t/' "${health_log}"
expect_rejection "an IPv4-mapped loopback process impersonating public egress"
write_fixture "${health_log}"

/usr/bin/sed -i '' '3s/\t1024\t-\t-\t-\thealthy/\t0\t-\t-\t-\thealthy/' "${health_log}"
expect_rejection "egress without decoded audio"
write_fixture "${health_log}"

/usr/bin/sed -i '' '5s/offsite-cellular/offsite-wifi/' "${health_log}"
expect_rejection "an observer identity change during proof"
write_fixture "${health_log}"

/usr/bin/sed -i '' '5s/ffmpeg version fixture/ffmpeg version replacement/' "${health_log}"
expect_rejection "an observer software change during proof"
write_fixture "${health_log}"

write_fixture "${health_log}" 330000 1
expect_rejection "an egress playlist whose media sequence never advances"
write_fixture "${health_log}"

write_fixture "${health_log}" 200000
expect_rejection "health coverage shorter than the requested proof window"
write_fixture "${health_log}"

/usr/bin/plutil -replace scene -string worship "${manifest}"
expect_rejection "health evidence paired with the wrong rollout phase"
/usr/bin/plutil -replace scene -string sermon "${manifest}"

verify >/dev/null

/usr/bin/env python3 \
  "${script_directory}/../failover/test_automix_failover_supervisor.py"

print "stream-health-evidence self-test PASS"
