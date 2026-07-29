#!/bin/zsh
set -euo pipefail

script_name="${0:t}"

usage() {
  print -u2 "Usage: DEVELOPER_ID_APPLICATION='Developer ID Application: …' \\"
  print -u2 "       NOTARY_KEYCHAIN_PROFILE='notary-profile' ${script_name} [OUTPUT_ROOT]"
}

if (( $# > 1 )); then
  usage
  exit 2
fi

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
project_path="${repo_root}/native/AutoMixNative.xcodeproj"
entitlements_path="${repo_root}/native/AutoMixNative/AutoMixNative.entitlements"
output_root="${1:-${repo_root}/native/build/release}"
signing_identity="${DEVELOPER_ID_APPLICATION:-}"
notary_profile="${NOTARY_KEYCHAIN_PROFILE:-}"

if [[ -z "${signing_identity}" || -z "${notary_profile}" ]]; then
  print -u2 "Developer ID identity and notary Keychain profile are required."
  usage
  exit 2
fi

if [[ -n "$(git -C "${repo_root}" status --porcelain)" ]]; then
  print -u2 "Refusing a production release from a dirty worktree."
  exit 3
fi
source_commit="$(git -C "${repo_root}" rev-parse HEAD)"
if [[ ! "${source_commit}" =~ '^[0-9a-f]{40}$' ]] ||
    ! git -C "${repo_root}" merge-base --is-ancestor HEAD origin/main; then
  print -u2 "Refusing a production release whose exact source commit is not published to origin/main."
  exit 3
fi

if ! /usr/bin/security find-identity -v -p codesigning |
  /usr/bin/grep -F -- "\"${signing_identity}\"" >/dev/null; then
  print -u2 "Code-signing identity is not available in this login Keychain:"
  print -u2 "  ${signing_identity}"
  exit 4
fi

/bin/mkdir -p "${output_root}"
output_root="${output_root:A}"
release_temp_parent="${TMPDIR:-/tmp}"
release_temp_parent="${release_temp_parent:A}"
build_root="$(mktemp -d "${release_temp_parent}/automix-release.XXXXXX")"
cleanup() {
  if [[ -n "${build_root:-}" &&
        "${build_root}" == "${release_temp_parent}/automix-release."* &&
        -d "${build_root}" ]]; then
    /bin/rm -rf -- "${build_root}"
  fi
}
trap cleanup EXIT INT TERM

derived_data="${build_root}/DerivedData"
/usr/bin/xcodebuild \
  -project "${project_path}" \
  -scheme AutoMixNative \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "${derived_data}" \
  CODE_SIGNING_ALLOWED=NO \
  build

source_app="${derived_data}/Build/Products/Release/AutoMix Native.app"
if [[ ! -x "${source_app}/Contents/MacOS/AutoMix Native" ]]; then
  print -u2 "Release build did not produce the expected app bundle."
  exit 5
fi

staged_app="${build_root}/AutoMix Native.app"
/usr/bin/ditto "${source_app}" "${staged_app}"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
  "${staged_app}/Contents/Info.plist")"
build_number="$(/usr/bin/plutil -extract CFBundleVersion raw -o - \
  "${staged_app}/Contents/Info.plist")"
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
  "${staged_app}/Contents/Info.plist")"
minimum_system_version="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - \
  "${staged_app}/Contents/Info.plist")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
built_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# This source identity is sealed inside the notarized app. External metadata alone
# can be copied or mixed between releases; the signed resource makes the commit,
# version, and bundle identity part of the app's code-signature envelope.
provenance_name="AutoMixReleaseProvenance.plist"
provenance_path="${staged_app}/Contents/Resources/${provenance_name}"
/bin/mkdir -p "${provenance_path:h}"
/usr/bin/plutil -create xml1 "${provenance_path}"
/usr/bin/plutil -insert formatVersion -integer 1 "${provenance_path}"
/usr/bin/plutil -insert kind -string automix-native-signed-provenance "${provenance_path}"
/usr/bin/plutil -insert sourceCommit -string "${source_commit}" "${provenance_path}"
/usr/bin/plutil -insert builtAtUTC -string "${built_at_utc}" "${provenance_path}"
/usr/bin/plutil -insert version -string "${version}" "${provenance_path}"
/usr/bin/plutil -insert build -string "${build_number}" "${provenance_path}"
/usr/bin/plutil -insert bundleIdentifier -string "${bundle_identifier}" "${provenance_path}"
/usr/bin/plutil -lint "${provenance_path}"

/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "${entitlements_path}" \
  --sign "${signing_identity}" \
  "${staged_app}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${staged_app}"
if ! /usr/bin/codesign -dv --verbose=4 "${staged_app}" 2>&1 |
  /usr/bin/grep -F "(runtime)" >/dev/null; then
  print -u2 "Signed app is missing the Hardened Runtime code-signature flag."
  exit 5
fi
signed_entitlements="${build_root}/signed-entitlements.plist"
/usr/bin/codesign --display \
  --entitlements "${signed_entitlements}" \
  --xml \
  "${staged_app}"
/usr/bin/plutil -lint "${signed_entitlements}"
audio_input_entitlement="$(/usr/bin/plutil \
  -extract 'com\.apple\.security\.device\.audio-input' \
  raw -o - "${signed_entitlements}" 2>/dev/null || true)"
if [[ "${audio_input_entitlement}" != "true" ]]; then
  print -u2 "Signed app is missing the required CoreAudio input entitlement."
  exit 5
fi
debug_entitlement="$(/usr/bin/plutil \
  -extract 'com\.apple\.security\.get-task-allow' \
  raw -o - "${signed_entitlements}" 2>/dev/null || true)"
if [[ "${debug_entitlement}" == "true" ]]; then
  print -u2 "Production app must not retain the debugger get-task-allow entitlement."
  exit 5
fi

submission_zip="${build_root}/AutoMix-Native-notary-submission.zip"
/usr/bin/ditto \
  -c -k --sequesterRsrc --keepParent \
  "${staged_app}" \
  "${submission_zip}"

notary_result="${build_root}/notary-result.json"
/usr/bin/xcrun notarytool submit "${submission_zip}" \
  --keychain-profile "${notary_profile}" \
  --wait \
  --output-format json |
  /usr/bin/tee "${notary_result}"

notary_status="$(/usr/bin/plutil -extract status raw -o - "${notary_result}" 2>/dev/null || true)"
if [[ "${notary_status}" != "Accepted" ]]; then
  print -u2 "Apple notarization did not return Accepted."
  exit 6
fi

/usr/bin/xcrun stapler staple "${staged_app}"
/usr/bin/xcrun stapler validate "${staged_app}"
/usr/sbin/spctl --assess --type execute --verbose=4 "${staged_app}"

release_dir="${output_root}/automix-native-${version}-${timestamp}"
if [[ -e "${release_dir}" ]]; then
  print -u2 "Release directory already exists: ${release_dir}"
  exit 7
fi
/bin/mkdir "${release_dir}"

final_app="${release_dir}/AutoMix Native.app"
/usr/bin/ditto "${staged_app}" "${final_app}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${final_app}"
/usr/bin/xcrun stapler validate "${final_app}"
/usr/sbin/spctl --assess --type execute --verbose=4 "${final_app}"
/bin/cp "${notary_result}" "${release_dir}/notary-result.json"
/bin/cp "${signed_entitlements}" "${release_dir}/signed-entitlements.plist"

final_binary="${final_app}/Contents/MacOS/AutoMix Native"
final_provenance="${final_app}/Contents/Resources/${provenance_name}"
app_binary_sha256="$(/usr/bin/shasum -a 256 "${final_binary}" | /usr/bin/awk '{print $1}')"
signed_provenance_sha256="$(/usr/bin/shasum -a 256 "${final_provenance}" | /usr/bin/awk '{print $1}')"

metadata_plist="${build_root}/build-metadata.plist"
/usr/bin/plutil -create xml1 "${metadata_plist}"
/usr/bin/plutil -insert formatVersion -integer 1 "${metadata_plist}"
/usr/bin/plutil -insert kind -string automix-native-release-build "${metadata_plist}"
/usr/bin/plutil -insert version -string "${version}" "${metadata_plist}"
/usr/bin/plutil -insert build -string "${build_number}" "${metadata_plist}"
/usr/bin/plutil -insert commit -string "${source_commit}" "${metadata_plist}"
/usr/bin/plutil -insert builtAtUTC -string "${built_at_utc}" "${metadata_plist}"
/usr/bin/plutil -insert bundleIdentifier -string "${bundle_identifier}" "${metadata_plist}"
/usr/bin/plutil -insert minimumSystemVersion -string "${minimum_system_version}" "${metadata_plist}"
/usr/bin/plutil -insert signingIdentity -string "${signing_identity}" "${metadata_plist}"
/usr/bin/plutil -insert hardenedRuntime -bool true "${metadata_plist}"
/usr/bin/plutil -insert notarized -bool true "${metadata_plist}"
/usr/bin/plutil -insert audioInputEntitlement -bool true "${metadata_plist}"
/usr/bin/plutil -insert appBinarySHA256 -string "${app_binary_sha256}" "${metadata_plist}"
/usr/bin/plutil -insert signedProvenanceResource -string "Contents/Resources/${provenance_name}" "${metadata_plist}"
/usr/bin/plutil -insert signedProvenanceSHA256 -string "${signed_provenance_sha256}" "${metadata_plist}"
/usr/bin/plutil -convert json -o "${release_dir}/build-metadata.json" "${metadata_plist}"

archive="${release_dir}/AutoMix-Native-${version}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${final_app}" "${archive}"
(
  cd "${release_dir}"
  /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256"
)

print "Notarized release ready:"
print "  ${final_app}"
print "  ${archive}"
