#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
fixture_root="$(/usr/bin/mktemp -d /tmp/live-daw-runtime-incident-test.XXXXXX)"
cleanup() {
  if [[ "${fixture_root}" == /tmp/live-daw-runtime-incident-test.* && -d "${fixture_root}" ]]; then
    /bin/rm -rf "${fixture_root}"
  fi
}
trap cleanup EXIT INT TERM

manifest="${fixture_root}/manifest.json"
journal="${fixture_root}/runtime-incidents.jsonl"
report="${fixture_root}/runtime-incident-evidence.json"
window_start=1780000000000
window_end=1780000330000

/usr/bin/plutil -create xml1 "${manifest}"
/usr/bin/plutil -insert scene -string sermon "${manifest}"
/usr/bin/plutil -insert hardwareProofPassed -bool true "${manifest}"
/usr/bin/plutil -insert soundcheckSeconds -float 30.0 "${manifest}"
/usr/bin/plutil -insert stabilitySeconds -float 300.0 "${manifest}"
/usr/bin/plutil -convert json "${manifest}"

write_clean_journal() {
  print -r -- '{"details":{"state":"starting"},"kind":"engine-started","message":"Core Audio engine started","severity":"info","timestampMs":1779999999000}' > "${journal}"
  print -r -- '{"details":{"state":"healthy"},"kind":"engine-healthy","message":"Engine entered healthy state","severity":"info","timestampMs":1780000001000}' >> "${journal}"
}

record() {
  "${script_directory}/record-runtime-incident-evidence.sh" \
    --journal "${journal}" \
    --manifest "${manifest}" \
    --phase sermon \
    --window-start-ms "${window_start}" \
    --window-end-ms "${window_end}" \
    --output "${report}" \
    --replace
}

verify() {
  "${script_directory}/verify-runtime-incident-evidence.sh" \
    --report "${report}" \
    --manifest "${manifest}" \
    --expected-phase sermon
}

expect_rejection() {
  local label="$1"
  if verify >/dev/null 2>&1; then
    print -u2 "Runtime-incident verifier accepted ${label}."
    exit 1
  fi
}

write_clean_journal
record >/dev/null
verify >/dev/null

/usr/bin/plutil -replace incidents.0.severity -string warning "${report}"
expect_rejection "a warning incident hidden behind passing totals"
record >/dev/null

/usr/bin/plutil -replace windowEndedAtMs -integer 1780000100000 "${report}"
expect_rejection "an incident window shorter than the hardware proof"
record >/dev/null

/usr/bin/plutil -replace fullCheckManifestSHA256 -string \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "${report}"
expect_rejection "incident evidence bound to another manifest"
record >/dev/null

print -r -- '{"kind":"broken"}' >> "${journal}"
if record >/dev/null 2>&1; then
  print -u2 "Runtime-incident recorder accepted a malformed journal line."
  exit 1
fi
write_clean_journal

record >/dev/null
verify >/dev/null
print "runtime-incident-evidence self-test PASS"
