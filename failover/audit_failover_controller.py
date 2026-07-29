#!/usr/bin/env python3
"""Audit the independent failover controller immediately before a proof run."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import stat
import subprocess
import sys
import time
import urllib.parse
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Optional

from automix_failover_supervisor import (
    FORMAT_VERSION as SUPERVISOR_FORMAT_VERSION,
    STATUS_KIND,
    ConfigurationError,
    load_supervisor_configuration,
)


FORMAT_VERSION = 1
KIND = "automix-failover-controller-readiness"
SERVICE_NAME = "automix-failover.service"
MAX_DOCUMENT_BYTES = 64 * 1024
MAX_STATUS_AGE_MS = 2_000
REPORT_LIFETIME_MS = 15 * 60 * 1_000
EXPECTED_CHECK_IDS = {
    "controller.separate-failure-domain",
    "controller.production-config",
    "controller.software-unit-integrity",
    "controller.systemd-service",
    "relay.fresh-backup-latch",
}


@dataclass(frozen=True)
class Check:
    id: str
    passed: bool
    summary: str
    remediation: str


def safe_text(value: Any, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and value == value.strip()
        and len(value) <= maximum
        and not any(
            ord(character) <= 31 or ord(character) == 127
            for character in value
        )
    )


def hash_file(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"cannot hash non-regular file {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def load_private_json(path: Path) -> dict[str, Any]:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValueError(f"cannot open private status: {error.strerror}") from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("status must be a regular file")
        if info.st_mode & 0o077:
            raise ValueError("status must not be group/world accessible")
        if info.st_size <= 0 or info.st_size > MAX_DOCUMENT_BYTES:
            raise ValueError("status must contain 1 byte to 64 KiB")
        raw = b""
        while len(raw) <= MAX_DOCUMENT_BYTES:
            block = os.read(
                descriptor,
                min(65_536, MAX_DOCUMENT_BYTES + 1 - len(raw)),
            )
            if not block:
                break
            raw += block
    finally:
        os.close(descriptor)
    if len(raw) > MAX_DOCUMENT_BYTES:
        raise ValueError("status exceeds 64 KiB")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("status is not valid UTF-8 JSON") from error
    if not isinstance(payload, dict):
        raise ValueError("status must be a JSON object")
    return payload


def read_systemd_properties() -> dict[str, str]:
    property_names = (
        "LoadState",
        "ActiveState",
        "SubState",
        "UnitFileState",
        "User",
        "Group",
        "Restart",
        "NoNewPrivileges",
        "ProtectSystem",
        "NeedDaemonReload",
        "MainPID",
        "FragmentPath",
    )
    try:
        arguments = [
            "systemctl",
            "show",
            SERVICE_NAME,
            "--no-pager",
        ]
        for property_name in property_names:
            arguments.extend(["--property", property_name])
        result = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
    except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired) as error:
        raise ValueError("systemctl could not inspect the failover service") from error
    if result.returncode != 0:
        raise ValueError("systemctl rejected the failover service")
    properties: dict[str, str] = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in property_names:
            properties[key] = value
    if set(properties) != set(property_names):
        raise ValueError("systemctl response is incomplete")
    return properties


def systemd_service_ready(
    properties: dict[str, str], unit_path: Path
) -> tuple[bool, str]:
    try:
        main_pid = int(properties.get("MainPID", "0"))
        fragment_matches = (
            Path(properties.get("FragmentPath", "")).resolve()
            == unit_path.resolve()
        )
    except (OSError, ValueError):
        return False, "systemd service properties are malformed"
    passed = (
        properties.get("LoadState") == "loaded"
        and properties.get("ActiveState") == "active"
        and properties.get("SubState") == "running"
        and properties.get("UnitFileState") == "enabled"
        and properties.get("User") == "automix-failover"
        and properties.get("Group") == "automix-failover"
        and properties.get("Restart") == "always"
        and properties.get("NoNewPrivileges") == "yes"
        and properties.get("ProtectSystem") == "strict"
        and properties.get("NeedDaemonReload") == "no"
        and main_pid > 0
        and fragment_matches
    )
    return (
        passed,
        "hardened failover service is enabled and running"
        if passed
        else "failover service is not enabled, running, or hardened as packaged",
    )


def backup_status_ready(
    payload: dict[str, Any], now_ms: int
) -> tuple[bool, str]:
    updated_at = payload.get("updatedAtMs")
    fresh = (
        isinstance(updated_at, int)
        and not isinstance(updated_at, bool)
        and -250 <= now_ms - updated_at <= MAX_STATUS_AGE_MS
    )
    passed = (
        payload.get("formatVersion") == SUPERVISOR_FORMAT_VERSION
        and payload.get("kind") == STATUS_KIND
        and payload.get("selectedInput") == "backup"
        and payload.get("backupLatched") is True
        and payload.get("manualReturnRequired") is True
        and payload.get("relayConfirmed") is True
        and payload.get("primaryLeaseRemainingMs") == 0
        and safe_text(payload.get("relayRequestId"), 128)
        and fresh
    )
    return (
        passed,
        "fresh status confirms the physical relay is latched to backup"
        if passed
        else "status is stale or does not confirm a latched physical backup selection",
    )


def path_integrity_ready(
    supervisor_path: Path,
    audit_path: Path,
    unit_path: Path,
    expected_owner_uid: int = 0,
    expected_owner_gid: int = 0,
) -> tuple[bool, str, Optional[str], Optional[str], Optional[str]]:
    supervisor_sha: Optional[str] = None
    audit_sha: Optional[str] = None
    unit_sha: Optional[str] = None
    try:
        supervisor_info = supervisor_path.lstat()
        audit_info = audit_path.lstat()
        unit_info = unit_path.lstat()
        paths_valid = (
            stat.S_ISREG(supervisor_info.st_mode)
            and stat.S_ISREG(audit_info.st_mode)
            and stat.S_ISREG(unit_info.st_mode)
            and not supervisor_path.is_symlink()
            and not audit_path.is_symlink()
            and not unit_path.is_symlink()
            and supervisor_info.st_uid == expected_owner_uid
            and audit_info.st_uid == expected_owner_uid
            and unit_info.st_uid == expected_owner_uid
            and supervisor_info.st_gid == expected_owner_gid
            and audit_info.st_gid == expected_owner_gid
            and unit_info.st_gid == expected_owner_gid
            and os.access(supervisor_path, os.X_OK)
            and os.access(audit_path, os.X_OK)
            and supervisor_info.st_mode & 0o022 == 0
            and audit_info.st_mode & 0o022 == 0
            and unit_info.st_mode & 0o022 == 0
        )
        supervisor_sha = hash_file(supervisor_path)
        audit_sha = hash_file(audit_path)
        unit_sha = hash_file(unit_path)
        passed = paths_valid
    except (OSError, ValueError):
        passed = False
    return (
        passed,
        "installed supervisor, audit tool, and unit are root-owned, regular, non-writable package files"
        if passed
        else "installed supervisor, audit tool, or systemd unit is missing, linked, wrongly owned, or writable",
        supervisor_sha,
        audit_sha,
        unit_sha,
    )


def audit_controller(
    *,
    config_path: Path,
    status_path: Path,
    unit_path: Path,
    supervisor_path: Path,
    audit_path: Optional[Path] = None,
    primary_hostname: str,
    now_ms: Optional[int] = None,
    controller_hostname: Optional[str] = None,
    systemd_reader: Callable[[], dict[str, str]] = read_systemd_properties,
    expected_package_uid: int = 0,
    expected_package_gid: int = 0,
) -> dict[str, Any]:
    observed_ms = int(time.time() * 1_000) if now_ms is None else now_ms
    actual_audit_path = (
        Path(__file__).resolve() if audit_path is None else audit_path
    )
    actual_controller = (
        socket.gethostname()
        if controller_hostname is None
        else controller_hostname
    )
    checks: list[Check] = []
    separate = (
        safe_text(primary_hostname, 253)
        and safe_text(actual_controller, 253)
        and primary_hostname.casefold() != actual_controller.casefold()
    )
    checks.append(
        Check(
            "controller.separate-failure-domain",
            separate,
            (
                f"controller {actual_controller} is separate from primary {primary_hostname}"
                if separate
                else "controller and primary host identities are missing or identical"
            ),
            "Run the supervisor on a separately powered controller and pass the AutoMix Mac's exact hostname.",
        )
    )

    configuration = None
    config_sha: Optional[str] = None
    heartbeat_host: Optional[str] = None
    relay_host: Optional[str] = None
    try:
        config_sha_before = hash_file(config_path)
        configuration = load_supervisor_configuration(config_path)
        config_sha = hash_file(config_path)
        if config_sha != config_sha_before:
            raise ValueError("production config changed during validation")
        heartbeat_host = urllib.parse.urlsplit(
            configuration.heartbeat_url
        ).hostname
        relay_host = urllib.parse.urlsplit(configuration.relay_url).hostname
        config_ready = (
            configuration.production_contract
            and safe_text(heartbeat_host, 253)
            and safe_text(relay_host, 253)
        )
        config_summary = (
            "strict production config and private relay credential validated"
            if config_ready
            else "production config endpoint identity is incomplete"
        )
    except (ConfigurationError, OSError, ValueError) as error:
        config_ready = False
        config_summary = f"production config rejected: {error}"
    checks.append(
        Check(
            "controller.production-config",
            config_ready,
            config_summary,
            "Reinstall with failover/install-systemd-service.sh and a private relay token.",
        )
    )

    (
        integrity_ready,
        integrity_summary,
        supervisor_sha,
        audit_sha,
        unit_sha,
    ) = path_integrity_ready(
        supervisor_path,
        actual_audit_path,
        unit_path,
        expected_package_uid,
        expected_package_gid,
    )
    checks.append(
        Check(
            "controller.software-unit-integrity",
            integrity_ready,
            integrity_summary,
            "Reinstall the exact repository supervisor and systemd unit as root-owned package files.",
        )
    )

    try:
        systemd_properties = systemd_reader()
        service_ready, service_summary = systemd_service_ready(
            systemd_properties, unit_path
        )
    except (OSError, ValueError) as error:
        systemd_properties = {}
        service_ready = False
        service_summary = f"systemd inspection failed: {error}"
    checks.append(
        Check(
            "controller.systemd-service",
            service_ready,
            service_summary,
            "Enable and start automix-failover.service using the checked-in installer.",
        )
    )

    status: dict[str, Any] = {}
    try:
        status = load_private_json(status_path)
        status_ready, status_summary = backup_status_ready(
            status, observed_ms
        )
    except (OSError, ValueError) as error:
        status_ready = False
        status_summary = f"backup status rejected: {error}"
    checks.append(
        Check(
            "relay.fresh-backup-latch",
            status_ready,
            status_summary,
            "Keep the relay's physical default on backup and resolve connectivity until a fresh backup acknowledgement is recorded.",
        )
    )

    failed = [check for check in checks if not check.passed]
    return {
        "formatVersion": FORMAT_VERSION,
        "kind": KIND,
        "generatedAtMs": observed_ms,
        "expiresAtMs": observed_ms + REPORT_LIFETIME_MS,
        "ready": not failed,
        "notProductionAcceptance": True,
        "primaryHostname": primary_hostname,
        "controllerHostname": actual_controller,
        "serviceName": SERVICE_NAME,
        "config": {
            "sha256": config_sha,
            "productionContract": (
                configuration.production_contract
                if configuration is not None
                else None
            ),
            "heartbeatHost": heartbeat_host,
            "relayHost": relay_host,
        },
        "software": {
            "supervisorSHA256": supervisor_sha,
            "auditSHA256": audit_sha,
            "unitSHA256": unit_sha,
        },
        "service": {
            "loadState": systemd_properties.get("LoadState"),
            "activeState": systemd_properties.get("ActiveState"),
            "subState": systemd_properties.get("SubState"),
            "unitFileState": systemd_properties.get("UnitFileState"),
            "user": systemd_properties.get("User"),
            "group": systemd_properties.get("Group"),
            "restart": systemd_properties.get("Restart"),
            "noNewPrivileges": systemd_properties.get("NoNewPrivileges"),
            "protectSystem": systemd_properties.get("ProtectSystem"),
            "needDaemonReload": systemd_properties.get("NeedDaemonReload"),
            "mainPID": systemd_properties.get("MainPID"),
            "fragmentPath": systemd_properties.get("FragmentPath"),
        },
        "relay": {
            "selectedInput": status.get("selectedInput"),
            "backupLatched": status.get("backupLatched"),
            "manualReturnRequired": status.get("manualReturnRequired"),
            "relayConfirmed": status.get("relayConfirmed"),
            "relayRequestId": status.get("relayRequestId"),
            "statusUpdatedAtMs": status.get("updatedAtMs"),
            "primaryLeaseRemainingMs": status.get(
                "primaryLeaseRemainingMs"
            ),
        },
        "summary": {
            "passed": len(checks) - len(failed),
            "failed": len(failed),
            "total": len(checks),
        },
        "checks": [asdict(check) for check in checks],
        "remainingAcceptanceScope": [
            "physical power/network/carrier kill tests",
            "selected encoder output recordings",
            "measured switch time and broadcast-safe backup audio",
        ],
    }


def write_report(path: Path, report: dict[str, Any], replace: bool) -> None:
    if path.is_symlink():
        raise ValueError("output must not be a symlink")
    if path.exists() and not replace:
        raise FileExistsError(f"refusing to overwrite {path}; pass --replace")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Audit the independent AutoMix failover controller immediately "
            "before transferring its readiness report to the production Mac."
        )
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("/etc/automix-failover/supervisor.json"),
    )
    parser.add_argument(
        "--status",
        type=Path,
        default=Path("/run/automix-failover/status.json"),
    )
    parser.add_argument(
        "--unit",
        type=Path,
        default=Path("/etc/systemd/system/automix-failover.service"),
    )
    parser.add_argument(
        "--supervisor",
        type=Path,
        default=Path(
            "/usr/local/libexec/automix-failover/"
            "automix_failover_supervisor.py"
        ),
    )
    parser.add_argument("--primary-hostname", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--replace", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_arguments(sys.argv[1:] if argv is None else argv)
    report = audit_controller(
        config_path=args.config,
        status_path=args.status,
        unit_path=args.unit,
        supervisor_path=args.supervisor,
        primary_hostname=args.primary_hostname,
    )
    try:
        write_report(args.output, report, args.replace)
    except (OSError, ValueError) as error:
        print(f"failover readiness report failed: {error}", file=sys.stderr)
        return 2
    summary = report["summary"]
    print(
        f"Failover controller readiness: ready={str(report['ready']).lower()} "
        f"passed={summary['passed']} failed={summary['failed']} "
        f"report={args.output}"
    )
    for check in report["checks"]:
        if not check["passed"]:
            print(f"BLOCKED {check['id']}: {check['summary']}")
    return 0 if report["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
