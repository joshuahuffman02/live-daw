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
print -r -- "operator@example.test $(<"${key_path}.pub")" > "${trusted_signers}"
/bin/mkdir "${bundle}"

source "${script_directory}/test-support/create-production-evidence-fixtures.sh"
create_production_evidence_fixtures "${fixture_root}/production-evidence"

labels=(
  build-metadata
  full-check-manifest
  continuous-recording-report
  app-integrity
  stream-health
  external-failover
  latency-lipsync
  runtime-resilience
  replay-comparison
)
typeset -A evidence_paths
for label in "${labels[@]}"; do
  path="${fixture_root}/${label}.txt"
  if [[ "${label}" == "build-metadata" ]]; then
    /usr/bin/plutil -create xml1 "${path}"
    /usr/bin/plutil -insert commit -string 0123456789abcdef0123456789abcdef01234567 "${path}"
    /usr/bin/plutil -convert json "${path}"
  elif [[ -n "${production_evidence_paths[${label}]:-}" ]]; then
    path="${production_evidence_paths[${label}]}"
  elif [[ "${label}" == "full-check-manifest" ]]; then
    path="${production_evidence_attachments[full-check-manifest]}"
  else
    print -r -- "fixture ${label}" > "${path}"
  fi
  evidence_paths[${label}]="${path}"
done

plist="${bundle}/acceptance.plist"
json="${bundle}/acceptance.json"
/usr/bin/plutil -create xml1 "${plist}"
/usr/bin/plutil -insert formatVersion -integer 1 "${plist}"
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
/usr/bin/ssh-keygen -Y sign -f "${key_path}" -n live-daw-acceptance "${json}" >/dev/null

"${script_directory}/verify-proof-acceptance.sh" \
  --acceptance-dir "${bundle}" \
  --trusted-signers "${trusted_signers}" \
  --expected-phase sermon \
  --expected-decision approved \
  --manifest "${evidence_paths[full-check-manifest]}" >/dev/null

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

print -r -- "fixture stream-health" > "${evidence_paths[stream-health]}"
print -r -- " " >> "${json}"
if "${script_directory}/verify-proof-acceptance.sh" \
    --acceptance-dir "${bundle}" \
    --trusted-signers "${trusted_signers}" >/dev/null 2>&1; then
  print -u2 "Verifier accepted an acceptance payload changed after signing."
  exit 1
fi

print "proof-acceptance self-test PASS"
