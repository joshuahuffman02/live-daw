#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
source_bridge="${repo_root}/encoder/obs_health_bridge.py"
template_path="${repo_root}/encoder/com.livedaw.obshealthbridge.plist.template"
label="com.livedaw.obshealthbridge"
install_directory="${HOME}/Library/Application Support/AutoMix OBS Health"
installed_bridge="${install_directory}/obs_health_bridge.py"
installed_password="${install_directory}/obs-websocket-password"
log_directory="${HOME}/Library/Logs/AutoMix OBS Health"
stdout_log="${log_directory}/stdout.log"
stderr_log="${log_directory}/stderr.log"
launch_agents="${HOME}/Library/LaunchAgents"
destination="${launch_agents}/${label}.plist"
password_source=""
selector_flag=""
selector_value=""
audio_track="1"

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --password-file /private/obs-password --audio-input-name 'Program Audio' [--audio-track 1]"
  print -u2 "  $0 --password-file /private/obs-password --audio-input-uuid OBS_INPUT_UUID [--audio-track 1]"
}

while (( $# > 0 )); do
  case "$1" in
    --password-file)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      password_source="$2"
      shift 2
      ;;
    --audio-input-name|--audio-input-uuid)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      if [[ -n "${selector_flag}" ]]; then
        print -u2 "Configure exactly one OBS audio input name or UUID."
        exit 2
      fi
      selector_flag="$1"
      selector_value="$2"
      shift 2
      ;;
    --audio-track)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      audio_track="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${password_source}" || -z "${selector_flag}" || -z "${selector_value}" ]]; then
  usage
  exit 2
fi
if [[ ! -f "${password_source}" || -L "${password_source}" ]]; then
  print -u2 "OBS password source must be a regular, non-symlink file: ${password_source}"
  exit 2
fi
if [[ ! -f "${source_bridge}" || ! -f "${template_path}" ]]; then
  print -u2 "OBS health bridge sources are missing from ${repo_root}."
  exit 2
fi

python_executable="$(command -v python3 2>/dev/null || true)"
if [[ -z "${python_executable}" || "${python_executable}" != /* || ! -x "${python_executable}" ]]; then
  print -u2 "An absolute executable python3 path is required."
  exit 2
fi

"${python_executable}" -B "${source_bridge}" \
  --password-file "${password_source}" \
  "${selector_flag}" "${selector_value}" \
  --audio-track "${audio_track}" \
  --check-config

/bin/mkdir -p "${install_directory}" "${log_directory}" "${launch_agents}"
/bin/chmod 700 "${install_directory}" "${log_directory}"
/bin/cp "${source_bridge}" "${installed_bridge}"
/bin/chmod 700 "${installed_bridge}"
/bin/cp "${password_source}" "${installed_password}"
/bin/chmod 600 "${installed_password}"
/usr/bin/touch "${stdout_log}" "${stderr_log}"
/bin/chmod 600 "${stdout_log}" "${stderr_log}"

"${python_executable}" -B "${installed_bridge}" \
  --password-file "${installed_password}" \
  "${selector_flag}" "${selector_value}" \
  --audio-track "${audio_track}" \
  --check-config

staging_directory="$(mktemp -d)"
trap '/bin/rm -rf "${staging_directory}"' EXIT
staged_plist="${staging_directory}/${label}.plist"
/bin/cp "${template_path}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.0 -string "${python_executable}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.2 -string "${installed_bridge}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.8 -string "${installed_password}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.9 -string "${selector_flag}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.10 -string "${selector_value}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.12 -string "${audio_track}" "${staged_plist}"
/usr/bin/plutil -replace WorkingDirectory -string "${install_directory}" "${staged_plist}"
/usr/bin/plutil -replace StandardOutPath -string "${stdout_log}" "${staged_plist}"
/usr/bin/plutil -replace StandardErrorPath -string "${stderr_log}" "${staged_plist}"
/usr/bin/plutil -lint "${staged_plist}"

/bin/cp "${staged_plist}" "${destination}"
/bin/chmod 600 "${destination}"
/bin/launchctl bootout "gui/${UID}/${label}" 2>/dev/null || true
/bin/launchctl bootstrap "gui/${UID}" "${destination}"
/bin/launchctl enable "gui/${UID}/${label}"
/bin/launchctl kickstart -k "gui/${UID}/${label}"

health_url="http://127.0.0.1:8421/health"
typeset -i attempt=0
while (( attempt < 30 )); do
  if /usr/bin/curl --silent --show-error --fail --max-time 1 \
      -H "Accept: application/json" "${health_url}" >/dev/null; then
    print "Installed ${destination}"
    print "Encoder health endpoint: ${health_url}"
    print "Configure AutoMix encoderHealthURL with that exact URL."
    exit 0
  fi
  attempt="$(( attempt + 1 ))"
  /bin/sleep 0.1
done

print -u2 "OBS health bridge did not start. Inspect ${stderr_log}."
exit 3
