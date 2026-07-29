#!/usr/bin/env bash
set -euo pipefail
umask 077

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
supervisor_source="${script_directory}/automix_failover_supervisor.py"
audit_source="${script_directory}/audit_failover_controller.py"
unit_source="${script_directory}/automix-failover.service"
service_user="automix-failover"
heartbeat_url=""
relay_url=""
token_source=""
render_root="/"

usage() {
  >&2 echo "Usage: $0 --heartbeat-url URL --relay-url HTTPS_URL --relay-token-file PATH"
  >&2 echo "          [--render-root ABSOLUTE_DIRECTORY]"
  >&2 echo
  >&2 echo "Without --render-root this installs and starts the hardened systemd service."
  >&2 echo "A non-root render directory builds the exact filesystem payload without systemd."
}

while (($# > 0)); do
  case "$1" in
    --heartbeat-url)
      (($# >= 2)) || { usage; exit 2; }
      heartbeat_url="$2"
      shift 2
      ;;
    --relay-url)
      (($# >= 2)) || { usage; exit 2; }
      relay_url="$2"
      shift 2
      ;;
    --relay-token-file)
      (($# >= 2)) || { usage; exit 2; }
      token_source="$2"
      shift 2
      ;;
    --render-root)
      (($# >= 2)) || { usage; exit 2; }
      render_root="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${heartbeat_url}" || -z "${relay_url}" || -z "${token_source}" ]]; then
  usage
  exit 2
fi
if [[ "${render_root}" != /* || -L "${render_root}" ]]; then
  >&2 echo "Render root must be an absolute, non-symlink directory."
  exit 2
fi
if [[ ! -f "${token_source}" || -L "${token_source}" ]]; then
  >&2 echo "Relay token source must be a regular, non-symlink file."
  exit 2
fi
if [[ ! -f "${supervisor_source}" ||
      ! -f "${audit_source}" ||
      ! -f "${unit_source}" ]]; then
  >&2 echo "Failover supervisor package sources are incomplete."
  exit 2
fi

local_python="$(command -v python3 || true)"
if [[ -z "${local_python}" || "${local_python}" != /* || ! -x "${local_python}" ]]; then
  >&2 echo "An absolute executable python3 is required to validate the package."
  exit 2
fi
local_ssh_keygen="$(command -v ssh-keygen || true)"
if [[ -z "${local_ssh_keygen}" ||
      "${local_ssh_keygen}" != /* ||
      ! -x "${local_ssh_keygen}" ]]; then
  >&2 echo "An absolute executable ssh-keygen is required for controller identity."
  exit 2
fi
"${local_python}" - "${token_source}" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
info = os.lstat(path)
if not stat.S_ISREG(info.st_mode):
    raise SystemExit("Relay token source must be a regular file.")
if stat.S_IMODE(info.st_mode) & 0o077:
    raise SystemExit("Relay token source must not be group/world accessible.")
if info.st_size <= 0 or info.st_size > 4097:
    raise SystemExit("Relay token source must contain 1 byte to 4097 bytes.")
PY

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/automix-failover-install.XXXXXX")"
cleanup() {
  if [[ "${temporary_directory}" == "${TMPDIR:-/tmp}"/automix-failover-install.* &&
        -d "${temporary_directory}" ]]; then
    rm -rf "${temporary_directory}"
  fi
}
trap cleanup EXIT INT TERM

staged_token="${temporary_directory}/relay-token"
staged_config="${temporary_directory}/supervisor.json"
install -m 0600 "${token_source}" "${staged_token}"
"${local_python}" - "${staged_config}" "${heartbeat_url}" "${relay_url}" <<'PY'
import json
import os
import sys

destination, heartbeat_url, relay_url = sys.argv[1:]
payload = {
    "formatVersion": 1,
    "kind": "automix-failover-supervisor-config",
    "heartbeatUrl": heartbeat_url,
    "relayUrl": relay_url,
    "relayBearerTokenFile": "relay-token",
    "pollIntervalMs": 250,
    "heartbeatTimeoutMs": 500,
    "relayTimeoutMs": 500,
    "primaryLeaseMs": 1500,
    "requiredHealthySamples": 3,
    "controlSocket": "/run/automix-failover/control.sock",
    "statusPath": "/run/automix-failover/status.json",
    "journalPath": "/var/lib/automix-failover/events.jsonl",
}
descriptor = os.open(
    destination,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
    0o600,
)
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
"${local_python}" -B "${supervisor_source}" check-config \
  --config "${staged_config}" >/dev/null

if [[ "${render_root}" == "/" ]]; then
  if ((EUID != 0)); then
    >&2 echo "System installation must run as root."
    exit 2
  fi
  if [[ "$(uname -s)" != "Linux" ||
        ! -x /usr/bin/python3 ||
        -z "$(command -v systemctl || true)" ||
        -z "$(command -v useradd || true)" ]]; then
    >&2 echo "Production installation requires Linux, /usr/bin/python3, useradd, and systemd."
    exit 2
  fi
  if ! id "${service_user}" >/dev/null 2>&1; then
    useradd --system \
      --home-dir /var/lib/automix-failover \
      --shell /usr/sbin/nologin \
      "${service_user}"
  fi
else
  mkdir -p "${render_root}"
fi

library_directory="${render_root%/}/usr/local/libexec/automix-failover"
configuration_directory="${render_root%/}/etc/automix-failover"
unit_directory="${render_root%/}/etc/systemd/system"
installed_supervisor="${library_directory}/automix_failover_supervisor.py"
installed_audit="${library_directory}/audit_failover_controller.py"
installed_token="${configuration_directory}/relay-token"
installed_config="${configuration_directory}/supervisor.json"
installed_signing_key="${configuration_directory}/readiness-signing-key"
installed_signing_public_key="${installed_signing_key}.pub"
installed_unit="${unit_directory}/automix-failover.service"

"${local_python}" - "${render_root}" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
for relative in (
    "usr/local/libexec/automix-failover",
    "etc/automix-failover",
    "etc/systemd/system",
):
    current = root
    for component in Path(relative).parts:
        current /= component
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            break
        if not stat.S_ISDIR(info.st_mode):
            raise SystemExit(
                f"Installation directory chain contains a symlink or non-directory: {current}"
            )
PY
mkdir -p "${library_directory}" "${configuration_directory}" "${unit_directory}"
chmod 0755 "${library_directory}"
chmod 0700 "${configuration_directory}"
for destination in \
  "${installed_supervisor}" \
  "${installed_audit}" \
  "${installed_token}" \
  "${installed_config}" \
  "${installed_signing_key}" \
  "${installed_signing_public_key}" \
  "${installed_unit}"; do
  if [[ -L "${destination}" || (-e "${destination}" && ! -f "${destination}") ]]; then
    >&2 echo "Refusing unsafe installation target: ${destination}"
    exit 2
  fi
done
install -m 0755 "${supervisor_source}" "${installed_supervisor}"
install -m 0755 "${audit_source}" "${installed_audit}"
install -m 0600 "${token_source}" "${installed_token}"
install -m 0644 "${unit_source}" "${installed_unit}"
"${local_python}" - "${installed_config}" "${heartbeat_url}" "${relay_url}" <<'PY'
import json
import os
import sys

destination, heartbeat_url, relay_url = sys.argv[1:]
payload = {
    "formatVersion": 1,
    "kind": "automix-failover-supervisor-config",
    "heartbeatUrl": heartbeat_url,
    "relayUrl": relay_url,
    "relayBearerTokenFile": "relay-token",
    "pollIntervalMs": 250,
    "heartbeatTimeoutMs": 500,
    "relayTimeoutMs": 500,
    "primaryLeaseMs": 1500,
    "requiredHealthySamples": 3,
    "controlSocket": "/run/automix-failover/control.sock",
    "statusPath": "/run/automix-failover/status.json",
    "journalPath": "/var/lib/automix-failover/events.jsonl",
}
descriptor = os.open(
    destination,
    os.O_WRONLY
    | os.O_CREAT
    | os.O_TRUNC
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NOFOLLOW", 0),
    0o600,
)
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
os.chmod(destination, 0o600)
PY
chmod 0600 "${installed_config}"

if [[ ! -e "${installed_signing_key}" ]]; then
  "${local_ssh_keygen}" -q \
    -t ed25519 \
    -N "" \
    -C "automix-failover-controller" \
    -f "${installed_signing_key}"
fi
staged_public_key="${temporary_directory}/readiness-signing-key.pub"
"${local_ssh_keygen}" -y \
  -P "" \
  -f "${installed_signing_key}" > "${staged_public_key}"
read -r signing_key_type _signing_key_material _signing_key_comment \
  < "${staged_public_key}"
if [[ "${signing_key_type}" != "ssh-ed25519" ]]; then
  >&2 echo "Controller readiness signing key must be an unencrypted Ed25519 key."
  exit 2
fi
install -m 0644 "${staged_public_key}" "${installed_signing_public_key}"
chmod 0600 "${installed_signing_key}"
chmod 0644 "${installed_signing_public_key}"

if [[ "${render_root}" != "/" ]]; then
  echo "Rendered hardened failover package at ${render_root}"
  exit 0
fi

chown -R root:root "${library_directory}" "${configuration_directory}"
chmod 0755 "${installed_supervisor}" "${installed_audit}"
chmod 0600 \
  "${installed_config}" \
  "${installed_token}" \
  "${installed_signing_key}"
chmod 0644 "${installed_signing_public_key}"
chmod 0644 "${installed_unit}"

/usr/bin/python3 -B "${installed_supervisor}" check-config \
  --config "${installed_config}" >/dev/null

systemctl daemon-reload
systemctl enable --now automix-failover.service

ready=0
for _attempt in $(seq 1 40); do
  if systemctl is-active --quiet automix-failover.service &&
     /usr/bin/python3 - /run/automix-failover/status.json <<'PY'
import json
import os
import stat
import sys
import time

path = sys.argv[1]
info = os.lstat(path)
if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
    raise SystemExit(1)
with open(path, "r", encoding="utf-8") as stream:
    payload = json.load(stream)
fresh = int(time.time() * 1000) - payload.get("updatedAtMs", 0) <= 2000
valid = (
    payload.get("formatVersion") == 1
    and payload.get("kind") == "automix-failover-supervisor-status"
    and payload.get("selectedInput") == "backup"
    and payload.get("backupLatched") is True
    and payload.get("relayConfirmed") is True
    and fresh
)
raise SystemExit(0 if valid else 1)
PY
  then
    ready=1
    break
  fi
  sleep 0.1
done

if ((ready == 0)); then
  >&2 echo "Failover service is installed but did not prove a fresh, relay-confirmed backup latch."
  >&2 echo "It remains active and continues requesting backup. Inspect: systemctl status automix-failover"
  exit 3
fi

echo "Installed and enabled automix-failover.service."
echo "The relay confirmed backup; an operator must deliberately return to primary after health proof."
echo "Controller trust key: ${installed_signing_public_key}"
