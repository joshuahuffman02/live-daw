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

if ! /usr/bin/security find-identity -v -p codesigning |
  /usr/bin/grep -F -- "\"${signing_identity}\"" >/dev/null; then
  print -u2 "Code-signing identity is not available in this login Keychain:"
  print -u2 "  ${signing_identity}"
  exit 4
fi

/bin/mkdir -p "${output_root}"
output_root="${output_root:A}"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/automix-release.XXXXXX")"
trap 'rm -rf "${build_root}"' EXIT

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
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "${entitlements_path}" \
  --sign "${signing_identity}" \
  "${staged_app}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${staged_app}"

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

version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
  "${staged_app}/Contents/Info.plist")"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
release_dir="${output_root}/automix-native-${version}-${timestamp}"
if [[ -e "${release_dir}" ]]; then
  print -u2 "Release directory already exists: ${release_dir}"
  exit 7
fi
/bin/mkdir "${release_dir}"

final_app="${release_dir}/AutoMix Native.app"
/usr/bin/ditto "${staged_app}" "${final_app}"
/bin/cp "${notary_result}" "${release_dir}/notary-result.json"

metadata_plist="${build_root}/build-metadata.plist"
/usr/bin/plutil -create xml1 "${metadata_plist}"
/usr/bin/plutil -insert version -string "${version}" "${metadata_plist}"
/usr/bin/plutil -insert build -string \
  "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "${final_app}/Contents/Info.plist")" \
  "${metadata_plist}"
/usr/bin/plutil -insert commit -string "$(git -C "${repo_root}" rev-parse HEAD)" "${metadata_plist}"
/usr/bin/plutil -insert builtAtUTC -string "${timestamp}" "${metadata_plist}"
/usr/bin/plutil -insert hardenedRuntime -bool true "${metadata_plist}"
/usr/bin/plutil -insert notarized -bool true "${metadata_plist}"
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
