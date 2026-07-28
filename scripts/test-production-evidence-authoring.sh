#!/bin/zsh
set -euo pipefail

TRAPZERR() {
  local failure_code="$?"
  print -u2 "production-evidence-authoring self-test failed: status=${failure_code} at ${funcfiletrace[1]:-unknown}"
  return "${failure_code}"
}

script_directory="${0:A:h}"
fixture_root="$(/usr/bin/mktemp -d /tmp/live-daw-production-authoring-test.XXXXXX)"
cleanup() {
  if [[ "${fixture_root}" == /tmp/live-daw-production-authoring-test.* && -d "${fixture_root}" ]]; then
    /bin/rm -rf "${fixture_root}"
  fi
}
trap cleanup EXIT INT TERM

source "${script_directory}/test-support/create-production-evidence-fixtures.sh"
create_production_evidence_fixtures "${fixture_root}/fixtures"
manifest="${production_evidence_attachments[full-check-manifest]}"
candidate_commit=0123456789abcdef0123456789abcdef01234567

generated_drafts="${fixture_root}/generated-drafts"
rejected_output="${fixture_root}/rejected-output"
"${script_directory}/new-production-evidence-drafts.sh" \
  --phase sermon \
  --output-dir "${generated_drafts}" >/dev/null
if "${script_directory}/new-production-evidence-drafts.sh" \
    --phase sermon \
    --output-dir "${generated_drafts}" >/dev/null 2>&1; then
  print -u2 "Draft generator overwrote existing drafts without explicit --replace."
  exit 1
fi
if "${script_directory}/finalize-production-evidence.sh" \
    --draft-dir "${generated_drafts}" \
    --manifest "${manifest}" \
    --candidate-commit "${candidate_commit}" \
    --output-dir "${rejected_output}" \
    --require-approved-replay >/dev/null 2>&1; then
  print -u2 "Finalizer accepted untouched fail-closed draft templates."
  exit 1
fi

worship_drafts="${fixture_root}/worship-drafts"
"${script_directory}/new-production-evidence-drafts.sh" \
  --phase worship \
  --output-dir "${worship_drafts}" >/dev/null
worship_phase="$(/usr/bin/plutil -extract phase raw -o - \
  "${worship_drafts}/replay-comparison.json")"
worship_coverage_count="$(/usr/bin/plutil -extract comparisons.0.coverageTags raw -o - \
  "${worship_drafts}/replay-comparison.json")"
if [[ "${worship_phase}" != "worship" || "${worship_coverage_count}" != "11" ]]; then
  print -u2 "Worship drafts did not include the phase-specific dense-worship coverage gate."
  exit 1
fi

valid_drafts="${fixture_root}/valid-drafts"
final_output="${fixture_root}/final"
/bin/mkdir "${valid_drafts}"
for name in external-failover latency-lipsync runtime-resilience replay-comparison; do
  /bin/cp "${production_evidence_paths[${name}]}" "${valid_drafts}/${name}.json"
  /usr/bin/plutil -insert draft -bool true "${valid_drafts}/${name}.json"
  /usr/bin/plutil -insert draftInstructions -string "test-only draft marker" \
    "${valid_drafts}/${name}.json"
done

scrub_reference() {
  local report="$1"
  local prefix="$2"
  /usr/bin/plutil -replace "${prefix}.sha256" -string \
    0000000000000000000000000000000000000000000000000000000000000000 \
    "${report}"
  /usr/bin/plutil -replace "${prefix}.bytes" -integer 1 "${report}"
}

external="${valid_drafts}/external-failover.json"
scrub_reference "${external}" wiringDiagram
for index in {0..4}; do
  scrub_reference "${external}" "tests.${index}.recording"
done
latency="${valid_drafts}/latency-lipsync.json"
scrub_reference "${latency}" rawMeasurements
scrub_reference "${latency}" testRecording
runtime="${valid_drafts}/runtime-resilience.json"
for index in {0..6}; do
  scrub_reference "${runtime}" "tests.${index}.evidence"
done
replay="${valid_drafts}/replay-comparison.json"
for prefix in \
  comparisons.0.baseline.program \
  comparisons.0.baseline.metrics \
  comparisons.0.baseline.decisions \
  comparisons.0.candidate.program \
  comparisons.0.candidate.metrics \
  comparisons.0.candidate.decisions \
  comparisons.0.referenceMix; do
  scrub_reference "${replay}" "${prefix}"
done

"${script_directory}/finalize-production-evidence.sh" \
  --draft-dir "${valid_drafts}" \
  --manifest "${manifest}" \
  --candidate-commit "${candidate_commit}" \
  --output-dir "${final_output}" \
  --require-approved-replay >/dev/null

"${script_directory}/verify-production-evidence.sh" \
  --external-failover "${final_output}/external-failover.json" \
  --latency-lipsync "${final_output}/latency-lipsync.json" \
  --runtime-resilience "${final_output}/runtime-resilience.json" \
  --replay-comparison "${final_output}/replay-comparison.json" \
  --expected-manifest "${manifest}" \
  --expected-candidate-commit "${candidate_commit}" \
  --expected-phase sermon \
  --require-approved-replay >/dev/null

if /usr/bin/plutil -extract draft raw -o - "${final_output}/external-failover.json" \
    >/dev/null 2>&1; then
  print -u2 "Finalizer retained a draft marker."
  exit 1
fi
observed_commit="$(/usr/bin/plutil -extract candidateCommit raw -o - \
  "${final_output}/replay-comparison.json")"
if [[ "${observed_commit}" != "${candidate_commit}" ]]; then
  print -u2 "Finalizer did not bind the selected candidate commit."
  exit 1
fi
expected_wiring_sha="$(/usr/bin/shasum -a 256 "${production_evidence_attachments[wiring-diagram]}" |
  /usr/bin/awk '{print $1}')"
observed_wiring_sha="$(/usr/bin/plutil -extract wiringDiagram.sha256 raw -o - \
  "${final_output}/external-failover.json")"
if [[ "${observed_wiring_sha}" != "${expected_wiring_sha}" ]]; then
  print -u2 "Finalizer did not hash the selected wiring attachment."
  exit 1
fi

if "${script_directory}/finalize-production-evidence.sh" \
    --draft-dir "${valid_drafts}" \
    --manifest "${manifest}" \
    --candidate-commit "${candidate_commit}" \
    --output-dir "${final_output}" >/dev/null 2>&1; then
  print -u2 "Finalizer overwrote finalized reports without explicit --replace."
  exit 1
fi

print -r -- "modified after finalization" >> "${production_evidence_attachments[wiring-diagram]}"
if "${script_directory}/verify-production-evidence.sh" \
    --external-failover "${final_output}/external-failover.json" \
    --latency-lipsync "${final_output}/latency-lipsync.json" \
    --runtime-resilience "${final_output}/runtime-resilience.json" \
    --replay-comparison "${final_output}/replay-comparison.json" >/dev/null 2>&1; then
  print -u2 "Final evidence accepted an attachment modified after finalization."
  exit 1
fi

print "production-evidence-authoring self-test PASS"
