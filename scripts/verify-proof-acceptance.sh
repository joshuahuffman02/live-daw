#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --acceptance-dir DIR --trusted-signers FILE"
  print -u2 "     [--expected-phase sermon|worship] [--expected-decision approved|rejected]"
  print -u2 "     [--manifest PATH]"
}

acceptance_directory=""
trusted_signers=""
expected_phase=""
expected_decision=""
expected_manifest=""

while (( $# > 0 )); do
  case "$1" in
    --acceptance-dir)
      acceptance_directory="${2:-}"
      shift 2
      ;;
    --trusted-signers)
      trusted_signers="${2:-}"
      shift 2
      ;;
    --expected-phase)
      expected_phase="${2:-}"
      shift 2
      ;;
    --expected-decision)
      expected_decision="${2:-}"
      shift 2
      ;;
    --manifest)
      expected_manifest="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${acceptance_directory}" || -z "${trusted_signers}" ]]; then
  usage
  exit 2
fi

acceptance_json="${acceptance_directory}/acceptance.json"
acceptance_signature="${acceptance_directory}/acceptance.json.sig"
if [[ ! -s "${acceptance_json}" || ! -s "${acceptance_signature}" ]]; then
  print -u2 "Acceptance bundle must contain non-empty acceptance.json and acceptance.json.sig."
  exit 3
fi
if [[ ! -s "${trusted_signers}" ]]; then
  print -u2 "Trusted signer file is missing or empty: ${trusted_signers}"
  exit 3
fi
format_version="$(/usr/bin/plutil -extract formatVersion raw -o - "${acceptance_json}" 2>/dev/null || true)"
phase="$(/usr/bin/plutil -extract phase raw -o - "${acceptance_json}" 2>/dev/null || true)"
decision="$(/usr/bin/plutil -extract decision raw -o - "${acceptance_json}" 2>/dev/null || true)"
reviewer="$(/usr/bin/plutil -extract reviewer raw -o - "${acceptance_json}" 2>/dev/null || true)"
signer_identity="$(/usr/bin/plutil -extract signerIdentity raw -o - "${acceptance_json}" 2>/dev/null || true)"
source_commit="$(/usr/bin/plutil -extract sourceCommit raw -o - "${acceptance_json}" 2>/dev/null || true)"
evidence_count="$(/usr/bin/plutil -extract evidence raw -o - "${acceptance_json}" 2>/dev/null || true)"

if [[ "${format_version}" != "1" ||
      ( "${phase}" != "sermon" && "${phase}" != "worship" ) ||
      ( "${decision}" != "approved" && "${decision}" != "rejected" ) ||
      -z "${reviewer}" ||
      "${reviewer}" == *[[:cntrl:]]* ||
      ! "${signer_identity}" =~ '^[A-Za-z0-9._@+-]{1,128}$' ||
      ! "${source_commit}" =~ '^[0-9a-f]{40}$' ||
      ! "${evidence_count}" =~ '^[0-9]+$' ||
      ${evidence_count} -lt 9 ]]; then
  print -u2 "Acceptance metadata is incomplete or invalid."
  exit 3
fi
if [[ -n "${expected_phase}" && "${phase}" != "${expected_phase}" ]]; then
  print -u2 "Acceptance phase mismatch: expected ${expected_phase}, observed ${phase}."
  exit 4
fi
if [[ -n "${expected_decision}" && "${decision}" != "${expected_decision}" ]]; then
  print -u2 "Acceptance decision mismatch: expected ${expected_decision}, observed ${decision}."
  exit 4
fi

if ! /usr/bin/ssh-keygen -Y verify \
    -f "${trusted_signers}" \
    -I "${signer_identity}" \
    -n "live-daw-acceptance" \
    -s "${acceptance_signature}" \
    < "${acceptance_json}" >/dev/null; then
  print -u2 "Acceptance signature is invalid or the signer is not trusted."
  exit 5
fi

expected_manifest_sha=""
if [[ -n "${expected_manifest}" ]]; then
  if [[ ! -s "${expected_manifest}" ]]; then
    print -u2 "Expected manifest is missing or empty: ${expected_manifest}"
    exit 3
  fi
  expected_manifest_sha="$(/usr/bin/shasum -a 256 "${expected_manifest}" | /usr/bin/awk '{print $1}')"
fi

manifest_hash_matched=0
typeset -A seen_labels
typeset -A verified_evidence_paths
integer index=0
while (( index < evidence_count )); do
  prefix="evidence.${index}"
  label="$(/usr/bin/plutil -extract "${prefix}.label" raw -o - "${acceptance_json}" 2>/dev/null || true)"
  path="$(/usr/bin/plutil -extract "${prefix}.path" raw -o - "${acceptance_json}" 2>/dev/null || true)"
  expected_sha="$(/usr/bin/plutil -extract "${prefix}.sha256" raw -o - "${acceptance_json}" 2>/dev/null || true)"
  expected_bytes="$(/usr/bin/plutil -extract "${prefix}.bytes" raw -o - "${acceptance_json}" 2>/dev/null || true)"

  if [[ -z "${label}" || -n "${seen_labels[${label}]:-}" ||
        ! "${expected_sha}" =~ '^[0-9a-f]{64}$' ||
        ! "${expected_bytes}" =~ '^[0-9]+$' ||
        ${expected_bytes} -le 0 ||
        ! -s "${path}" ]]; then
    print -u2 "Acceptance evidence entry ${index} is invalid, duplicated, missing, or empty."
    exit 6
  fi
  seen_labels[${label}]=1
  verified_evidence_paths[${label}]="${path}"

  observed_sha="$(/usr/bin/shasum -a 256 "${path}" | /usr/bin/awk '{print $1}')"
  observed_bytes="$(/usr/bin/stat -f '%z' "${path}")"
  if [[ "${observed_sha}" != "${expected_sha}" || "${observed_bytes}" != "${expected_bytes}" ]]; then
    print -u2 "Acceptance evidence changed after signing: ${label} (${path})."
    exit 6
  fi
  if [[ "${label}" == "full-check-manifest" && -n "${expected_manifest_sha}" ]]; then
    if [[ "${observed_sha}" != "${expected_manifest_sha}" ]]; then
      print -u2 "Accepted full-check manifest does not match the supplied sermon manifest."
      exit 6
    fi
    manifest_hash_matched=1
  fi
  if [[ "${label}" == "build-metadata" ]]; then
    build_metadata_commit="$(/usr/bin/plutil -extract commit raw -o - "${path}" 2>/dev/null || true)"
    if [[ "${build_metadata_commit}" != "${source_commit}" ]]; then
      print -u2 "Build metadata commit does not match the signed acceptance source commit."
      exit 6
    fi
  fi
  index="$(( index + 1 ))"
done

required_labels=(
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
for label in "${required_labels[@]}"; do
  if [[ -z "${seen_labels[${label}]:-}" ]]; then
    print -u2 "Acceptance evidence is missing required item: ${label}."
    exit 6
  fi
done
if [[ "${phase}" == "worship" ]]; then
  for label in sermon-acceptance-json sermon-acceptance-signature; do
    if [[ -z "${seen_labels[${label}]:-}" ]]; then
      print -u2 "Worship acceptance is missing prerequisite item: ${label}."
      exit 6
    fi
  done
fi
if [[ -n "${expected_manifest_sha}" && "${manifest_hash_matched}" != "1" ]]; then
  print -u2 "Acceptance does not bind the supplied full-check manifest."
  exit 6
fi

production_evidence_arguments=(
  --external-failover "${verified_evidence_paths[external-failover]}"
  --latency-lipsync "${verified_evidence_paths[latency-lipsync]}"
  --runtime-resilience "${verified_evidence_paths[runtime-resilience]}"
  --replay-comparison "${verified_evidence_paths[replay-comparison]}"
  --expected-manifest "${verified_evidence_paths[full-check-manifest]}"
  --expected-candidate-commit "${source_commit}"
  --expected-phase "${phase}"
)
if [[ "${decision}" == "approved" ]]; then
  production_evidence_arguments+=(--require-approved-replay)
fi
"${script_directory}/verify-production-evidence.sh" \
  "${production_evidence_arguments[@]}" >/dev/null

print "Verified ${phase} acceptance: decision=${decision} reviewer=${reviewer} signer=${signer_identity} commit=${source_commit}"
