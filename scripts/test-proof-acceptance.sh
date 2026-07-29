#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
fixture_root="$(/usr/bin/mktemp -d /tmp/live-daw-acceptance-test.XXXXXX)"
cleanup() {
  if [[ "${fixture_root}" == /tmp/live-daw-acceptance-test.* && -d "${fixture_root}" ]]; then
    /bin/rm -rf "${fixture_root}"
  fi
}
trap cleanup EXIT INT TERM

key_path="${fixture_root}/operator"
trusted_signers="${fixture_root}/allowed_signers"
bundle="${fixture_root}/sermon-acceptance"
/usr/bin/ssh-keygen -q -t ed25519 -N "" -f "${key_path}"
operator_public_key="$(/bin/cat "${key_path}.pub")"
print -r -- "operator@example.test ${operator_public_key}" > "${trusted_signers}"
/bin/mkdir "${bundle}"

source "${script_directory}/test-support/create-production-evidence-fixtures.sh"
create_production_evidence_fixtures "${fixture_root}/production-evidence"

runtime_incident_journal="${fixture_root}/runtime-incidents.jsonl"
runtime_incident_report="${fixture_root}/runtime-incident-evidence.json"
print -r -- '{"details":{"state":"healthy"},"kind":"engine-healthy","message":"Engine healthy","severity":"info","timestampMs":1780000001000}' \
  > "${runtime_incident_journal}"
"${script_directory}/record-runtime-incident-evidence.sh" \
  --journal "${runtime_incident_journal}" \
  --manifest "${production_evidence_attachments[full-check-manifest]}" \
  --phase sermon \
  --window-start-ms 1780000000000 \
  --window-end-ms 1780007230000 \
  --output "${runtime_incident_report}" \
  --require-production-duration >/dev/null

write_stream_health_fixture() {
  local output="$1"
  /usr/bin/awk 'BEGIN {
    print "checkedAtMs\tprobe\tendpointPeer\tobserverKind\tformatVersion\tproductionEligible\tobserverIdentity\tsoftwareVersion\tplaybackHost\tmediaSequence\tdecodedAudioSamples\tauthenticated\tencoderProgressing\tencoderIntervalClean\tstate\tresponseTimestampMs\tageMs\thealthy\tstreaming\taudioActive\tdetail"
    base = 1780000000000
    for (offset = 0; offset <= 7230000; offset += 2000) {
      checked = base + offset
      response = checked - 1000
      sequence = 100 + int(offset / 4000)
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

labels=(
  build-metadata
  full-check-manifest
  continuous-recording-report
  app-integrity
  stream-health
  runtime-incidents
  external-failover
  latency-lipsync
  runtime-resilience
  replay-comparison
  rollout-observation
)
fixture_app_binary_sha="1111111111111111111111111111111111111111111111111111111111111111"
fixture_provenance_sha="2222222222222222222222222222222222222222222222222222222222222222"
signature_log="${fixture_root}/app-signature-verification.txt"
print -r -- "fixture signature, notarization, and Gatekeeper verification" > "${signature_log}"
signature_log_sha="$(/usr/bin/shasum -a 256 "${signature_log}" | /usr/bin/awk '{print $1}')"
typeset -A evidence_paths
for label in "${labels[@]}"; do
  path="${fixture_root}/${label}.txt"
  if [[ "${label}" == "build-metadata" ]]; then
    /usr/bin/plutil -create xml1 "${path}"
    /usr/bin/plutil -insert formatVersion -integer 1 "${path}"
    /usr/bin/plutil -insert kind -string automix-native-release-build "${path}"
    /usr/bin/plutil -insert commit -string 0123456789abcdef0123456789abcdef01234567 "${path}"
    /usr/bin/plutil -insert appBinarySHA256 -string "${fixture_app_binary_sha}" "${path}"
    /usr/bin/plutil -insert signedProvenanceSHA256 -string "${fixture_provenance_sha}" "${path}"
    /usr/bin/plutil -convert json "${path}"
  elif [[ "${label}" == "app-integrity" ]]; then
    build_metadata_sha="$(/usr/bin/shasum -a 256 "${evidence_paths[build-metadata]}" | /usr/bin/awk '{print $1}')"
    /usr/bin/plutil -create xml1 "${path}"
    /usr/bin/plutil -insert formatVersion -integer 1 "${path}"
    /usr/bin/plutil -insert kind -string automix-app-integrity "${path}"
    /usr/bin/plutil -insert sourceCommit -string 0123456789abcdef0123456789abcdef01234567 "${path}"
    /usr/bin/plutil -insert appBinarySHA256 -string "${fixture_app_binary_sha}" "${path}"
    /usr/bin/plutil -insert signedProvenanceSHA256 -string "${fixture_provenance_sha}" "${path}"
    /usr/bin/plutil -insert buildMetadataSHA256 -string "${build_metadata_sha}" "${path}"
    /usr/bin/plutil -insert signatureVerificationLogPath -string "${signature_log}" "${path}"
    /usr/bin/plutil -insert signatureVerificationLogSHA256 -string "${signature_log_sha}" "${path}"
    /usr/bin/plutil -insert signatureVerified -bool true "${path}"
    /usr/bin/plutil -insert notarizationStapled -bool true "${path}"
    /usr/bin/plutil -insert gatekeeperAccepted -bool true "${path}"
    /usr/bin/plutil -convert json "${path}"
  elif [[ -n "${production_evidence_paths[${label}]:-}" ]]; then
    path="${production_evidence_paths[${label}]}"
  elif [[ "${label}" == "full-check-manifest" ]]; then
    path="${production_evidence_attachments[full-check-manifest]}"
  elif [[ "${label}" == "stream-health" ]]; then
    write_stream_health_fixture "${path}"
  elif [[ "${label}" == "runtime-incidents" ]]; then
    path="${runtime_incident_report}"
  else
    print -r -- "fixture ${label}" > "${path}"
  fi
  evidence_paths[${label}]="${path}"
done

plist="${bundle}/acceptance.plist"
json="${bundle}/acceptance.json"
/usr/bin/plutil -create xml1 "${plist}"
/usr/bin/plutil -insert formatVersion -integer 2 "${plist}"
/usr/bin/plutil -insert bundleID -string "$(/usr/bin/uuidgen)" "${plist}"
/usr/bin/plutil -insert phase -string sermon "${plist}"
/usr/bin/plutil -insert decision -string approved "${plist}"
/usr/bin/plutil -insert reviewer -string "Acceptance Test" "${plist}"
/usr/bin/plutil -insert signerIdentity -string operator@example.test "${plist}"
/usr/bin/plutil -insert sourceCommit -string 0123456789abcdef0123456789abcdef01234567 "${plist}"
/usr/bin/plutil -insert reviewedAtUTC -string 2026-07-28T00:00:00Z "${plist}"
/usr/bin/plutil -insert notes -string "deterministic verifier fixture" "${plist}"
/usr/bin/plutil -insert decisionScope -string "advance to supervised worship proof" "${plist}"
/usr/bin/plutil -insert signerPublicKey -string "$(/usr/bin/ssh-keygen -y -f "${key_path}")" "${plist}"
/usr/bin/plutil -insert evidence -json '[]' "${plist}"

integer index=0
for label in "${labels[@]}"; do
  path="${evidence_paths[${label}]}"
  sha256="$(/usr/bin/shasum -a 256 "${path}" | /usr/bin/awk '{print $1}')"
  byte_count="$(/usr/bin/stat -f '%z' "${path}")"
  /usr/bin/plutil -insert "evidence.${index}" -json '{}' "${plist}"
  /usr/bin/plutil -insert "evidence.${index}.label" -string "${label}" "${plist}"
  /usr/bin/plutil -insert "evidence.${index}.path" -string "${path}" "${plist}"
  /usr/bin/plutil -insert "evidence.${index}.sha256" -string "${sha256}" "${plist}"
  /usr/bin/plutil -insert "evidence.${index}.bytes" -integer "${byte_count}" "${plist}"
  index="$(( index + 1 ))"
done
/usr/bin/plutil -convert json -o "${json}" "${plist}"
/bin/rm "${plist}"
resign_acceptance() {
  /bin/rm -f "${json}.sig"
  /usr/bin/ssh-keygen -Y sign -f "${key_path}" -n live-daw-acceptance "${json}" >/dev/null
}
resign_acceptance

"${script_directory}/verify-proof-acceptance.sh" \
  --acceptance-dir "${bundle}" \
  --trusted-signers "${trusted_signers}" \
  --expected-phase sermon \
  --expected-decision approved \
  --manifest "${evidence_paths[full-check-manifest]}" >/dev/null

integer app_integrity_index=0
while [[ "$(/usr/bin/plutil -extract "evidence.${app_integrity_index}.label" raw -o - "${json}")" !=
         "app-integrity" ]]; do
  app_integrity_index="$(( app_integrity_index + 1 ))"
done
/usr/bin/plutil -replace appBinarySHA256 -string \
  ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  "${evidence_paths[app-integrity]}"
app_integrity_sha="$(/usr/bin/shasum -a 256 "${evidence_paths[app-integrity]}" | /usr/bin/awk '{print $1}')"
app_integrity_bytes="$(/usr/bin/stat -f '%z' "${evidence_paths[app-integrity]}")"
/usr/bin/plutil -replace "evidence.${app_integrity_index}.sha256" -string \
  "${app_integrity_sha}" "${json}"
/usr/bin/plutil -replace "evidence.${app_integrity_index}.bytes" -integer \
  "${app_integrity_bytes}" "${json}"
resign_acceptance
if "${script_directory}/verify-proof-acceptance.sh" \
    --acceptance-dir "${bundle}" \
    --trusted-signers "${trusted_signers}" >/dev/null 2>&1; then
  print -u2 "Verifier accepted app integrity bound to a different release binary."
  exit 1
fi
/usr/bin/plutil -replace appBinarySHA256 -string \
  "${fixture_app_binary_sha}" "${evidence_paths[app-integrity]}"
app_integrity_sha="$(/usr/bin/shasum -a 256 "${evidence_paths[app-integrity]}" | /usr/bin/awk '{print $1}')"
app_integrity_bytes="$(/usr/bin/stat -f '%z' "${evidence_paths[app-integrity]}")"
/usr/bin/plutil -replace "evidence.${app_integrity_index}.sha256" -string \
  "${app_integrity_sha}" "${json}"
/usr/bin/plutil -replace "evidence.${app_integrity_index}.bytes" -integer \
  "${app_integrity_bytes}" "${json}"
resign_acceptance

wrong_manifest="${fixture_root}/wrong-manifest.txt"
print -r -- "different manifest" > "${wrong_manifest}"
if "${script_directory}/verify-proof-acceptance.sh" \
    --acceptance-dir "${bundle}" \
    --trusted-signers "${trusted_signers}" \
    --manifest "${wrong_manifest}" >/dev/null 2>&1; then
  print -u2 "Verifier accepted a manifest that was not bound by the signed decision."
  exit 1
fi

print -r -- "tampered evidence" >> "${evidence_paths[stream-health]}"
if "${script_directory}/verify-proof-acceptance.sh" \
    --acceptance-dir "${bundle}" \
    --trusted-signers "${trusted_signers}" >/dev/null 2>&1; then
  print -u2 "Verifier accepted evidence changed after signing."
  exit 1
fi

write_stream_health_fixture "${evidence_paths[stream-health]}"
print -r -- " " >> "${json}"
if "${script_directory}/verify-proof-acceptance.sh" \
    --acceptance-dir "${bundle}" \
    --trusted-signers "${trusted_signers}" >/dev/null 2>&1; then
  print -u2 "Verifier accepted an acceptance payload changed after signing."
  exit 1
fi

print "proof-acceptance self-test PASS"
