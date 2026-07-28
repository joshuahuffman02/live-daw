#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
fixture_root="$(/usr/bin/mktemp -d /tmp/live-daw-production-evidence-test.XXXXXX)"
cleanup() {
  if [[ "${fixture_root}" == /tmp/live-daw-production-evidence-test.* && -d "${fixture_root}" ]]; then
    /bin/rm -rf "${fixture_root}"
  fi
}
trap cleanup EXIT INT TERM

source "${script_directory}/test-support/create-production-evidence-fixtures.sh"
create_production_evidence_fixtures "${fixture_root}/fixtures"

verify() {
  "${script_directory}/verify-production-evidence.sh" \
    --external-failover "${production_evidence_paths[external-failover]}" \
    --latency-lipsync "${production_evidence_paths[latency-lipsync]}" \
    --runtime-resilience "${production_evidence_paths[runtime-resilience]}" \
    --replay-comparison "${production_evidence_paths[replay-comparison]}" \
    --rollout-observation "${production_evidence_paths[rollout-observation]}" \
    --expected-manifest "${production_evidence_attachments[full-check-manifest]}" \
    --expected-candidate-commit 0123456789abcdef0123456789abcdef01234567 \
    --expected-phase sermon \
    --require-approved-replay \
    --require-approved-rollout
}

expect_rejection() {
  local label="$1"
  if verify >/dev/null 2>&1; then
    print -u2 "Production evidence verifier accepted ${label}."
    exit 1
  fi
}

refresh_reference() {
  local report="$1"
  local prefix="$2"
  local path="$3"
  local sha256 byte_count
  sha256="$(/usr/bin/shasum -a 256 "${path}" | /usr/bin/awk '{print $1}')"
  byte_count="$(/usr/bin/stat -f '%z' "${path}")"
  /usr/bin/plutil -replace "${prefix}.sha256" -string "${sha256}" "${report}"
  /usr/bin/plutil -replace "${prefix}.bytes" -integer "${byte_count}" "${report}"
}

verify >/dev/null

/usr/bin/plutil -replace tests.0.switchTimeSeconds -float 2.1 \
  "${production_evidence_paths[external-failover]}"
expect_rejection "a failover switch time above two seconds"
/usr/bin/plutil -replace tests.0.switchTimeSeconds -float 1.2 \
  "${production_evidence_paths[external-failover]}"

print -r -- "tampered wiring diagram" >> "${production_evidence_attachments[wiring-diagram]}"
expect_rejection "an attachment changed after its report was produced"
print -r -- "fixture wiring-diagram.txt" > "${production_evidence_attachments[wiring-diagram]}"

/usr/bin/plutil -replace residualMedianOffsetMs -float 21.0 \
  "${production_evidence_paths[latency-lipsync]}"
expect_rejection "a residual A/V offset above the venue limit"
/usr/bin/plutil -replace residualMedianOffsetMs -float 8.0 \
  "${production_evidence_paths[latency-lipsync]}"

/usr/bin/plutil -replace driftObservation.msPerHour -float 2.2 \
  "${production_evidence_paths[latency-lipsync]}"
expect_rejection "a drift rate inconsistent with its duration and offset change"
/usr/bin/plutil -replace driftObservation.msPerHour -float 2.0 \
  "${production_evidence_paths[latency-lipsync]}"

/usr/bin/plutil -replace tests.5.automaticRestartObserved -bool true \
  "${production_evidence_paths[runtime-resilience]}"
expect_rejection "an automatic restart after operator Stop"
/usr/bin/plutil -replace tests.5.automaticRestartObserved -bool false \
  "${production_evidence_paths[runtime-resilience]}"

/usr/bin/plutil -replace comparisons.0.checks.noUnexpectedSilence -bool false \
  "${production_evidence_paths[replay-comparison]}"
expect_rejection "an approved replay comparison with unexpected silence"
/usr/bin/plutil -replace comparisons.0.checks.noUnexpectedSilence -bool true \
  "${production_evidence_paths[replay-comparison]}"

/usr/bin/plutil -replace safetyPassed -bool false \
  "${production_evidence_attachments[replay-candidate-metrics]}"
refresh_reference \
  "${production_evidence_paths[replay-comparison]}" \
  comparisons.0.candidate.metrics \
  "${production_evidence_attachments[replay-candidate-metrics]}"
expect_rejection "candidate metrics whose own safety result failed"
/usr/bin/plutil -replace safetyPassed -bool true \
  "${production_evidence_attachments[replay-candidate-metrics]}"
refresh_reference \
  "${production_evidence_paths[replay-comparison]}" \
  comparisons.0.candidate.metrics \
  "${production_evidence_attachments[replay-candidate-metrics]}"

/usr/bin/plutil -replace blockSize -integer 512 \
  "${production_evidence_attachments[replay-candidate-metrics]}"
refresh_reference \
  "${production_evidence_paths[replay-comparison]}" \
  comparisons.0.candidate.metrics \
  "${production_evidence_attachments[replay-candidate-metrics]}"
expect_rejection "baseline and candidate replay metrics with different render configuration"
/usr/bin/plutil -replace blockSize -integer 256 \
  "${production_evidence_attachments[replay-candidate-metrics]}"
refresh_reference \
  "${production_evidence_paths[replay-comparison]}" \
  comparisons.0.candidate.metrics \
  "${production_evidence_attachments[replay-candidate-metrics]}"

print -r -- '{"tick":2}' >> "${production_evidence_attachments[replay-candidate-decisions]}"
refresh_reference \
  "${production_evidence_paths[replay-comparison]}" \
  comparisons.0.candidate.decisions \
  "${production_evidence_attachments[replay-candidate-decisions]}"
expect_rejection "a decision log whose line count differs from evaluator metrics"
/usr/bin/sed -i '' '$d' "${production_evidence_attachments[replay-candidate-decisions]}"
refresh_reference \
  "${production_evidence_paths[replay-comparison]}" \
  comparisons.0.candidate.decisions \
  "${production_evidence_attachments[replay-candidate-decisions]}"

/usr/bin/plutil -replace decision -string rejected \
  "${production_evidence_paths[replay-comparison]}"
expect_rejection "a rejected replay comparison for an approved promotion"
/usr/bin/plutil -replace decision -string approved \
  "${production_evidence_paths[replay-comparison]}"

/usr/bin/plutil -replace candidateCommit -string fedcba9876543210fedcba9876543210fedcba98 \
  "${production_evidence_paths[replay-comparison]}"
expect_rejection "a replay candidate that differs from the accepted source commit"
/usr/bin/plutil -replace candidateCommit -string 0123456789abcdef0123456789abcdef01234567 \
  "${production_evidence_paths[replay-comparison]}"

/usr/bin/plutil -replace shadowRehearsal.automationAppliedToProgram -bool true \
  "${production_evidence_paths[rollout-observation]}"
expect_rejection "an approved rollout that applied automation during SHADOW"
/usr/bin/plutil -replace shadowRehearsal.automationAppliedToProgram -bool false \
  "${production_evidence_paths[rollout-observation]}"

/usr/bin/plutil -replace supervisedService.humanOperatorPresent -bool false \
  "${production_evidence_paths[rollout-observation]}"
expect_rejection "an approved supervised service without a human operator"
/usr/bin/plutil -replace supervisedService.humanOperatorPresent -bool true \
  "${production_evidence_paths[rollout-observation]}"

/usr/bin/plutil -replace planningCenter.unexpectedSceneChangeCount -integer 1 \
  "${production_evidence_paths[rollout-observation]}"
expect_rejection "an approved rollout with an unexpected Planning Center scene change"
/usr/bin/plutil -replace planningCenter.unexpectedSceneChangeCount -integer 0 \
  "${production_evidence_paths[rollout-observation]}"

/usr/bin/plutil -replace decision -string rejected \
  "${production_evidence_paths[rollout-observation]}"
expect_rejection "a rejected rollout observation for an approved promotion"
/usr/bin/plutil -replace decision -string approved \
  "${production_evidence_paths[rollout-observation]}"

/usr/bin/plutil -replace candidateCommit -string fedcba9876543210fedcba9876543210fedcba98 \
  "${production_evidence_paths[rollout-observation]}"
expect_rejection "a rollout observation for a different source commit"
/usr/bin/plutil -replace candidateCommit -string 0123456789abcdef0123456789abcdef01234567 \
  "${production_evidence_paths[rollout-observation]}"

/usr/bin/plutil -replace supervisedService.completedAtUTC -string 2026-07-25T16:00:00Z \
  "${production_evidence_paths[rollout-observation]}"
expect_rejection "a supervised service timestamp before its SHADOW rehearsal"
/usr/bin/plutil -replace supervisedService.completedAtUTC -string 2026-07-27T16:00:00Z \
  "${production_evidence_paths[rollout-observation]}"

print -r -- "tampered cue trace" >> \
  "${production_evidence_attachments[planning-center-cue-trace]}"
expect_rejection "a Planning Center cue trace changed after finalization"
production_fixture_planning_center_cue_trace \
  "${production_evidence_attachments[planning-center-cue-trace]}"

/usr/bin/sed -i '' 's/"planID":"fixture-plan-001"/"planID":"different-plan"/g' \
  "${production_evidence_attachments[planning-center-cue-trace]}"
refresh_reference \
  "${production_evidence_paths[rollout-observation]}" \
  planningCenter.cueTrace \
  "${production_evidence_attachments[planning-center-cue-trace]}"
expect_rejection "a cue trace that belongs to a different Planning Center plan"
production_fixture_planning_center_cue_trace \
  "${production_evidence_attachments[planning-center-cue-trace]}"
refresh_reference \
  "${production_evidence_paths[rollout-observation]}" \
  planningCenter.cueTrace \
  "${production_evidence_attachments[planning-center-cue-trace]}"

/usr/bin/sed -i '' '$d' "${production_evidence_attachments[planning-center-cue-trace]}"
refresh_reference \
  "${production_evidence_paths[rollout-observation]}" \
  planningCenter.cueTrace \
  "${production_evidence_attachments[planning-center-cue-trace]}"
expect_rejection "a cue trace with fewer applied scenes than the rollout report"
production_fixture_planning_center_cue_trace \
  "${production_evidence_attachments[planning-center-cue-trace]}"
refresh_reference \
  "${production_evidence_paths[rollout-observation]}" \
  planningCenter.cueTrace \
  "${production_evidence_attachments[planning-center-cue-trace]}"

/usr/bin/plutil -replace phase -string worship \
  "${production_evidence_paths[runtime-resilience]}"
expect_rejection "runtime evidence from a different rollout phase"
/usr/bin/plutil -replace phase -string sermon \
  "${production_evidence_paths[runtime-resilience]}"

print -r -- "different full-check manifest" > "${fixture_root}/different-manifest.json"
if "${script_directory}/verify-production-evidence.sh" \
    --external-failover "${production_evidence_paths[external-failover]}" \
    --latency-lipsync "${production_evidence_paths[latency-lipsync]}" \
    --runtime-resilience "${production_evidence_paths[runtime-resilience]}" \
    --replay-comparison "${production_evidence_paths[replay-comparison]}" \
    --rollout-observation "${production_evidence_paths[rollout-observation]}" \
    --expected-manifest "${fixture_root}/different-manifest.json" >/dev/null 2>&1; then
  print -u2 "Production evidence verifier accepted reports bound to a different full-check manifest."
  exit 1
fi

verify >/dev/null
print "production-evidence self-test PASS"
