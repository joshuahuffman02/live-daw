#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
source_bridge="${repo_root}/egress/hls_health_bridge.py"
template_path="${repo_root}/egress/com.livedaw.hlsegresshealth.plist.template"
label="com.livedaw.hlsegresshealth"
install_directory="${HOME}/Library/Application Support/AutoMix HLS Egress"
installed_bridge="${install_directory}/hls_health_bridge.py"
installed_url="${install_directory}/public-hls-playback-url"
log_directory="${HOME}/Library/Logs/AutoMix HLS Egress"
stdout_log="${log_directory}/stdout.log"
stderr_log="${log_directory}/stderr.log"
launch_agents="${HOME}/Library/LaunchAgents"
destination="${launch_agents}/${label}.plist"
url_source=""
observer_site=""
listen_host="127.0.0.1"
listen_port="8422"
allow_remote=0

usage() {
  print -u2 "Usage:"
  print -u2 "  $0 --playlist-url-file /private/public-hls-url --observer-site 'REMOTE SITE'"
  print -u2 "     [--listen-host 127.0.0.1] [--listen-port 8422] [--allow-remote-health]"
}

while (( $# > 0 )); do
  case "$1" in
    --playlist-url-file)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      url_source="$2"
      shift 2
      ;;
    --observer-site)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      observer_site="$2"
      shift 2
      ;;
    --listen-host)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      listen_host="$2"
      shift 2
      ;;
    --listen-port)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      listen_port="$2"
      shift 2
      ;;
    --allow-remote-health)
      allow_remote=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${url_source}" || -z "${observer_site}" ]]; then
  usage
  exit 2
fi
if [[ ! -f "${url_source}" || -L "${url_source}" ]]; then
  print -u2 "HLS URL source must be a regular, non-symlink file: ${url_source}"
  exit 2
fi
if [[ ! -f "${source_bridge}" || ! -f "${template_path}" ]]; then
  print -u2 "HLS egress observer sources are missing from ${repo_root}."
  exit 2
fi

python_executable="$(command -v python3 2>/dev/null || true)"
ffmpeg_executable="$(command -v ffmpeg 2>/dev/null || true)"
if [[ -z "${python_executable}" || "${python_executable}" != /* || ! -x "${python_executable}" ]]; then
  print -u2 "An absolute executable python3 path is required."
  exit 2
fi
if [[ -z "${ffmpeg_executable}" || "${ffmpeg_executable}" != /* || ! -x "${ffmpeg_executable}" ]]; then
  print -u2 "FFmpeg is required. Install it with: brew install ffmpeg"
  exit 2
fi

typeset -a validation_arguments
validation_arguments=(
  --playlist-url-file "${url_source}"
  --observer-site "${observer_site}"
  --ffmpeg "${ffmpeg_executable}"
  --listen-host "${listen_host}"
  --listen-port "${listen_port}"
)
if (( allow_remote )); then
  validation_arguments+=(--allow-remote-health)
fi
"${python_executable}" -B "${source_bridge}" \
  "${validation_arguments[@]}" \
  --check-config

/bin/mkdir -p "${install_directory}" "${log_directory}" "${launch_agents}"
/bin/chmod 700 "${install_directory}" "${log_directory}"
/bin/cp "${source_bridge}" "${installed_bridge}"
/bin/chmod 700 "${installed_bridge}"
/bin/cp "${url_source}" "${installed_url}"
/bin/chmod 600 "${installed_url}"
/usr/bin/touch "${stdout_log}" "${stderr_log}"
/bin/chmod 600 "${stdout_log}" "${stderr_log}"

typeset -a installed_validation_arguments
installed_validation_arguments=(
  --playlist-url-file "${installed_url}"
  --observer-site "${observer_site}"
  --ffmpeg "${ffmpeg_executable}"
  --listen-host "${listen_host}"
  --listen-port "${listen_port}"
)
if (( allow_remote )); then
  installed_validation_arguments+=(--allow-remote-health)
fi
"${python_executable}" -B "${installed_bridge}" \
  "${installed_validation_arguments[@]}" \
  --check-config

staging_directory="$(mktemp -d)"
trap '/bin/rm -rf "${staging_directory}"' EXIT
staged_plist="${staging_directory}/${label}.plist"
/bin/cp "${template_path}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.0 -string "${python_executable}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.2 -string "${installed_bridge}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.4 -string "${installed_url}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.6 -string "${observer_site}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.8 -string "${ffmpeg_executable}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.10 -string "${listen_host}" "${staged_plist}"
/usr/bin/plutil -replace ProgramArguments.12 -string "${listen_port}" "${staged_plist}"
if (( allow_remote )); then
  /usr/bin/plutil -insert ProgramArguments.13 -string "--allow-remote-health" "${staged_plist}"
fi
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

health_host="${listen_host}"
if [[ "${listen_host}" == "0.0.0.0" ]]; then
  health_host="127.0.0.1"
elif [[ "${listen_host}" == "::" ]]; then
  health_host="[::1]"
elif [[ "${listen_host}" == *:* ]]; then
  health_host="[${listen_host}]"
fi
health_url="http://${health_host}:${listen_port}/health"
typeset -i attempt=0
while (( attempt < 30 )); do
  if /usr/bin/curl --silent --show-error --fail --max-time 1 \
      -H "Accept: application/json" "${health_url}" >/dev/null; then
    print "Installed ${destination}"
    print "Public HLS health endpoint: ${health_url}"
    print "Configure AutoMix egressHealthURL with the observer's VPN/firewall-protected address."
    exit 0
  fi
  attempt="$(( attempt + 1 ))"
  /bin/sleep 0.1
done

print -u2 "HLS egress observer did not start. Inspect ${stderr_log}."
exit 3
