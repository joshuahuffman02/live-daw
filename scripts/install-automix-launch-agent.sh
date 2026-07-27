#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
template_path="${repo_root}/native/launchd/com.livedaw.automixnative.plist.template"
app_path="${1:-/Applications/AutoMix Native.app}"
app_binary="${app_path}/Contents/MacOS/AutoMix Native"
label="com.livedaw.automixnative"
launch_agents="${HOME}/Library/LaunchAgents"
destination="${launch_agents}/${label}.plist"

if [[ ! -x "${app_binary}" ]]; then
  print -u2 "AutoMix executable not found or not executable: ${app_binary}"
  print -u2 "Usage: $0 '/absolute/path/to/AutoMix Native.app'"
  exit 2
fi

staging_dir="$(mktemp -d)"
trap 'rm -rf "${staging_dir}"' EXIT
staged_plist="${staging_dir}/${label}.plist"
cp "${template_path}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.0 -string "${app_binary}" "${staged_plist}"
/usr/bin/plutil -lint "${staged_plist}"

/bin/mkdir -p "${launch_agents}"
/bin/cp "${staged_plist}" "${destination}"
/bin/launchctl bootout "gui/${UID}/${label}" 2>/dev/null || true
/bin/launchctl bootstrap "gui/${UID}" "${destination}"
/bin/launchctl enable "gui/${UID}/${label}"
/bin/launchctl kickstart "gui/${UID}/${label}"

print "Installed ${destination}"
print "Crash relaunch is active. Use Stop in AutoMix before intentionally ending an autonomous session."
