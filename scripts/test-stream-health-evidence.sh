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
  /usr/bin/awk -v stop_ms="${stop_ms}" 'BEGIN {
    print "checkedAtMs\tprobe\tstate\tresponseTimestampMs\tageMs\thealthy\tstreaming\taudioActive\tdetail"
    base = 1780000000000
    for (offset = 0; offset <= stop_ms; offset += 2000) {
      checked = base + offset
      response = checked - 1000
      print checked "\tencoder\thealthy\t" response "\t1000\ttrue\ttrue\ttrue\tfresh live payload"
      print checked "\tegress\thealthy\t" response "\t1000\ttrue\ttrue\ttrue\tfresh live payload"
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

/usr/bin/sed -i '' '4s/\t1000\ttrue/\t16000\ttrue/' "${health_log}"
expect_rejection "a stale endpoint timestamp"
write_fixture "${health_log}"

/usr/bin/sed -i '' '5,10d' "${health_log}"
expect_rejection "an observation gap above seven seconds"
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
