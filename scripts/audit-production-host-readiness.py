#!/usr/bin/env python3
"""Fail-closed, read-only readiness audit for an AutoMix production proof host."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import math
import os
import plistlib
import socket
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


FORMAT_VERSION = 3
KIND = "automix-production-host-readiness"
FAILOVER_READINESS_KIND = "automix-failover-controller-readiness"
FAILOVER_READINESS_FORMAT_VERSION = 1
FAILOVER_READINESS_CHECK_IDS = {
    "controller.separate-failure-domain",
    "controller.production-config",
    "controller.software-unit-integrity",
    "controller.systemd-service",
    "relay.fresh-backup-latch",
}
PCO_KEYCHAIN_SERVICE = "com.livedaw.automixnative.planning-center"
AUTOMIX_LAUNCH_LABEL = "com.livedaw.automixnative"
RELEASE_PROVENANCE_KIND = "automix-native-signed-provenance"
RELEASE_METADATA_KIND = "automix-native-release-build"
RELEASE_PROVENANCE_RELATIVE_PATH = Path(
    "Contents/Resources/AutoMixReleaseProvenance.plist"
)
EXPECTED_CHECK_IDS = {
    "source.published-clean-commit",
    "app.signed-notarized-release",
    "audio.production-route-inventory",
    "audio.route-preflight",
    "profile.production-settings",
    "storage.proof-window-capacity",
    "planning-center.credentials",
    "runtime.crash-relaunch-agent",
    "failover.independent-controller",
    "encoder.obs-install",
    "encoder.exact-program-observer",
    "egress.remote-playback-observer",
}


@dataclass(frozen=True)
class Check:
    id: str
    category: str
    passed: bool
    summary: str
    remediation: str


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def load_document(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("must be a regular, non-symlink file")
    raw = path.read_bytes()
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        try:
            value = plistlib.loads(raw)
        except Exception as error:
            raise ValueError("is not valid JSON or property-list data") from error
    if not isinstance(value, dict):
        raise ValueError("must contain a top-level object")
    return value


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


def local_hostname() -> str:
    return socket.gethostname()


def valid_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def validate_failover_controller_readiness(
    path: Path,
    repo: Path,
    now_ms: int,
    primary_hostname: str | None = None,
) -> dict[str, Any]:
    report = load_document(path)
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError(
            "failover readiness permissions must be owner-only"
        )
    checks = report.get("checks")
    summary = report.get("summary")
    software = report.get("software")
    service = report.get("service")
    relay = report.get("relay")
    config = report.get("config")
    generated_at = report.get("generatedAtMs")
    expires_at = report.get("expiresAtMs")
    if (
        not isinstance(checks, list)
        or not isinstance(summary, dict)
        or not isinstance(software, dict)
        or not isinstance(service, dict)
        or not isinstance(relay, dict)
        or not isinstance(config, dict)
        or not isinstance(generated_at, int)
        or isinstance(generated_at, bool)
        or not isinstance(expires_at, int)
        or isinstance(expires_at, bool)
    ):
        raise ValueError("failover readiness structure is invalid")
    age_ms = now_ms - generated_at
    report_lifetime = expires_at - generated_at
    if (
        age_ms < -5_000
        or age_ms > 15 * 60 * 1_000
        or report_lifetime <= 0
        or report_lifetime > 15 * 60 * 1_000
        or now_ms > expires_at
    ):
        raise ValueError(
            "failover readiness is expired, stale, or future-dated"
        )
    expected_primary = primary_hostname or local_hostname()
    controller = report.get("controllerHostname")
    reported_primary = report.get("primaryHostname")
    identities_valid = (
        safe_text(expected_primary, 253)
        and safe_text(reported_primary, 253)
        and safe_text(controller, 253)
        and str(reported_primary).casefold()
        == str(expected_primary).casefold()
        and str(controller).casefold() != str(reported_primary).casefold()
    )
    expected_supervisor = repo / "failover" / "automix_failover_supervisor.py"
    expected_audit = repo / "failover" / "audit_failover_controller.py"
    expected_unit = repo / "failover" / "automix-failover.service"
    supervisor_sha = software.get("supervisorSHA256")
    audit_sha = software.get("auditSHA256")
    unit_sha = software.get("unitSHA256")
    software_valid = (
        valid_sha256(supervisor_sha)
        and valid_sha256(audit_sha)
        and valid_sha256(unit_sha)
        and hash_file(expected_supervisor) == supervisor_sha
        and hash_file(expected_audit) == audit_sha
        and hash_file(expected_unit) == unit_sha
    )
    check_ids = {
        item.get("id") for item in checks if isinstance(item, dict)
    }
    status_updated = relay.get("statusUpdatedAtMs")
    status_was_fresh = (
        isinstance(status_updated, int)
        and not isinstance(status_updated, bool)
        and -250 <= generated_at - status_updated <= 2_000
    )
    exact_contract = (
        report.get("formatVersion") == FAILOVER_READINESS_FORMAT_VERSION
        and report.get("kind") == FAILOVER_READINESS_KIND
        and report.get("ready") is True
        and report.get("notProductionAcceptance") is True
        and report.get("serviceName") == "automix-failover.service"
        and identities_valid
        and software_valid
        and check_ids == FAILOVER_READINESS_CHECK_IDS
        and len(checks) == len(FAILOVER_READINESS_CHECK_IDS)
        and all(
            isinstance(item, dict) and item.get("passed") is True
            for item in checks
        )
        and summary
        == {
            "passed": len(FAILOVER_READINESS_CHECK_IDS),
            "failed": 0,
            "total": len(FAILOVER_READINESS_CHECK_IDS),
        }
        and safe_text(config.get("heartbeatHost"), 253)
        and safe_text(config.get("relayHost"), 253)
        and valid_sha256(config.get("sha256"))
        and config.get("productionContract") is True
        and service.get("loadState") == "loaded"
        and service.get("activeState") == "active"
        and service.get("subState") == "running"
        and service.get("unitFileState") == "enabled"
        and service.get("user") == "automix-failover"
        and service.get("group") == "automix-failover"
        and service.get("restart") == "always"
        and service.get("noNewPrivileges") == "yes"
        and service.get("protectSystem") == "strict"
        and service.get("needDaemonReload") == "no"
        and service.get("fragmentPath")
        == "/etc/systemd/system/automix-failover.service"
        and isinstance(service.get("mainPID"), str)
        and service["mainPID"].isdigit()
        and int(service["mainPID"]) > 0
        and relay.get("selectedInput") == "backup"
        and relay.get("backupLatched") is True
        and relay.get("manualReturnRequired") is True
        and relay.get("relayConfirmed") is True
        and relay.get("primaryLeaseRemainingMs") == 0
        and safe_text(relay.get("relayRequestId"), 128)
        and status_was_fresh
    )
    if not exact_contract:
        raise ValueError(
            "failover readiness is incomplete, mismatched, or unsafe"
        )
    return report


def git_commit(repo: Path) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
            check=False,
        )
    except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip().lower()
    if result.returncode != 0 or len(value) != 40 or any(character not in "0123456789abcdef" for character in value):
        return None
    return value


def exact_health_url(value: Any, role: str) -> tuple[bool, str]:
    if not isinstance(value, str) or not value:
        return False, "not configured"
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        return False, "contains control characters"
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return False, "invalid URL"
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path != "/health"
    ):
        return False, "must be a token-free HTTP(S) URL with the exact /health path"
    host = parsed.hostname.lower()
    is_loopback = host == "localhost"
    try:
        address = ipaddress.ip_address(host)
        mapped = getattr(address, "ipv4_mapped", None)
        is_loopback = (
            is_loopback
            or address.is_loopback
            or address.is_unspecified
            or (mapped is not None and (mapped.is_loopback or mapped.is_unspecified))
        )
    except ValueError:
        pass
    if role == "encoder" and not is_loopback:
        return False, "encoder health must use numeric loopback"
    if role == "egress" and is_loopback:
        return False, "public-egress health must use a remote observer"
    return True, f"{parsed.scheme}://{parsed.hostname}{parsed.path}"


def run_quiet(arguments: list[str], timeout: float = 10) -> bool:
    try:
        result = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def production_signature_contract(app: Path) -> tuple[bool, str]:
    try:
        details = subprocess.run(
            ["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
        entitlements = subprocess.run(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
    except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired):
        return False, "could not inspect the production code-signature contract"
    try:
        detail_text = details.stderr.decode("utf-8", errors="replace")
        entitlement_document = plistlib.loads(entitlements.stdout)
    except (AttributeError, plistlib.InvalidFileException, TypeError, ValueError):
        return False, "code-signature details or entitlements are unreadable"
    developer_id = "Authority=Developer ID Application:" in detail_text
    hardened_runtime = "(runtime)" in detail_text
    team_bound = "TeamIdentifier=not set" not in detail_text and "TeamIdentifier=" in detail_text
    audio_input = (
        isinstance(entitlement_document, dict)
        and entitlement_document.get("com.apple.security.device.audio-input") is True
    )
    debug_disabled = (
        isinstance(entitlement_document, dict)
        and entitlement_document.get("com.apple.security.get-task-allow") is not True
    )
    passed = (
        details.returncode == 0
        and entitlements.returncode == 0
        and developer_id
        and hardened_runtime
        and team_bound
        and audio_input
        and debug_disabled
    )
    return (
        passed,
        "Developer ID, Hardened Runtime, production entitlements, and team identity verified"
        if passed
        else "app lacks Developer ID, Hardened Runtime, production entitlements, or team identity",
    )


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        return None


def fetch_json(url: str, timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        method="GET",
        headers={"Accept": "application/json", "Cache-Control": "no-cache"},
    )
    opener = urllib.request.build_opener(
        RejectRedirects,
        urllib.request.HTTPHandler,
        urllib.request.HTTPSHandler,
    )
    with opener.open(request, timeout=timeout) as response:
        if response.status != 200:
            raise ValueError(f"HTTP {response.status}")
        content_type = response.headers.get_content_type()
        if content_type != "application/json":
            raise ValueError(f"unexpected content type {content_type}")
        content_encoding = response.headers.get("Content-Encoding", "identity").lower()
        if content_encoding not in {"", "identity"}:
            raise ValueError("compressed health responses are not accepted")
        raw = response.read(65_537)
        if len(raw) > 65_536:
            raise ValueError("response exceeds 64 KiB")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("response is not a JSON object")
    return value


def safe_text(value: Any, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and len(value) <= maximum
        and not any(ord(character) < 32 or ord(character) == 127 for character in value)
    )


def healthy_observer(payload: dict[str, Any], role: str, now_ms: int) -> tuple[bool, str]:
    expected_kind = (
        "automix-obs-encoder-health"
        if role == "encoder"
        else "automix-hls-egress-health"
    )
    required = (
        payload.get("formatVersion") == 1
        and payload.get("kind") == expected_kind
        and payload.get("productionEligible") is True
        and payload.get("healthy") is True
        and payload.get("streaming") is True
        and payload.get("audioActive") is True
    )
    timestamp = payload.get("timestampMs")
    fresh = (
        isinstance(timestamp, int)
        and not isinstance(timestamp, bool)
        and -5_000 <= now_ms - timestamp <= 15_000
    )
    if not required or not fresh:
        return False, "observer contract is unhealthy, stale, or not production-eligible"
    if role == "encoder":
        exact_input = isinstance(payload.get("audioInput"), str) and bool(payload["audioInput"].strip())
        version = payload.get("obsStudioVersion")
        provenance = (
            payload.get("authenticated") is True
            and payload.get("encoderProgressing") is True
            and payload.get("encoderIntervalClean") is True
            and exact_input
            and safe_text(version, 128)
        )
        if not provenance:
            return False, "OBS observer lacks exact-input or advancing-encoder provenance"
        return True, "authenticated OBS exact-input and advancing-encoder health observed"
    media_sequence = payload.get("mediaSequence")
    decoded = payload.get("decodedAudioSamples")
    observer_site = payload.get("observerSite")
    playback_host = payload.get("playbackHost")
    if (
        not isinstance(media_sequence, int)
        or isinstance(media_sequence, bool)
        or not isinstance(decoded, int)
        or isinstance(decoded, bool)
        or decoded <= 0
        or not isinstance(observer_site, str)
        or not safe_text(observer_site, 256)
        or not isinstance(playback_host, str)
        or not safe_text(playback_host, 253)
    ):
        return False, "egress observer lacks sequence, decoded-audio, or remote-site provenance"
    return True, f"remote HLS sequence {media_sequence} and decoded audio observed"


class Auditor:
    def __init__(self, args: argparse.Namespace, now: dt.datetime | None = None):
        self.args = args
        self.now = now or utc_now()
        self.now_ms = int(self.now.timestamp() * 1_000)
        self.checks: list[Check] = []
        self.inventory: dict[str, Any] | None = None
        self.preflight: dict[str, Any] | None = None
        self.profile: dict[str, Any] | None = None
        self.build_metadata: dict[str, Any] | None = None
        self.failover_readiness: dict[str, Any] | None = None
        self.source_commit: str | None = None

    def add(
        self,
        check_id: str,
        category: str,
        passed: bool,
        summary: str,
        remediation: str,
    ) -> None:
        self.checks.append(Check(check_id, category, passed, summary, remediation))

    def audit_source(self) -> None:
        repo = self.args.repo
        self.source_commit = git_commit(repo)
        head_ok = self.source_commit is not None
        clean = run_quiet(["git", "-C", str(repo), "diff", "--quiet"]) and run_quiet(
            ["git", "-C", str(repo), "diff", "--cached", "--quiet"]
        )
        untracked = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "--others", "--exclude-standard"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        clean = clean and untracked.returncode == 0 and not untracked.stdout.strip()
        published = run_quiet(
            ["git", "-C", str(repo), "merge-base", "--is-ancestor", "HEAD", "origin/main"]
        )
        passed = head_ok and clean and published
        self.add(
            "source.published-clean-commit",
            "source",
            passed,
            "clean HEAD is published to origin/main" if passed else "source is dirty, invalid, or not published",
            "Commit intended production changes and push the exact HEAD to origin/main.",
        )

    def audit_app(self) -> None:
        app = self.args.app
        metadata_path = self.args.build_metadata
        if app is None or metadata_path is None:
            missing = "production app path" if app is None else "release build metadata"
            self.add(
                "app.signed-notarized-release",
                "application",
                False,
                f"{missing} was not supplied",
                "Build the Developer ID signed, notarized release and pass both --app and --build-metadata.",
            )
            return
        binary = app / "Contents" / "MacOS" / "AutoMix Native"
        info_path = app / "Contents" / "Info.plist"
        provenance_path = app / RELEASE_PROVENANCE_RELATIVE_PATH
        exists = (
            app.is_dir()
            and not app.is_symlink()
            and binary.is_file()
            and not binary.is_symlink()
            and os.access(binary, os.X_OK)
        )
        signed = exists and run_quiet(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        stapled = exists and run_quiet(["/usr/bin/xcrun", "stapler", "validate", str(app)])
        gatekeeper = exists and run_quiet(
            ["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)]
        )
        signature_contract, signature_summary = (
            production_signature_contract(app)
            if exists
            else (False, "production app is missing")
        )
        provenance_valid = False
        provenance_error = ""
        try:
            info = load_document(info_path)
            provenance = load_document(provenance_path)
            metadata = load_document(metadata_path)
            binary_sha = hash_file(binary)
            provenance_sha = hash_file(provenance_path)
            source_matches = (
                self.source_commit is not None
                and provenance.get("sourceCommit") == self.source_commit
                and metadata.get("commit") == self.source_commit
            )
            identity_matches = (
                provenance.get("version") == info.get("CFBundleShortVersionString")
                and provenance.get("build") == info.get("CFBundleVersion")
                and provenance.get("bundleIdentifier") == info.get("CFBundleIdentifier")
                and metadata.get("version") == provenance.get("version")
                and metadata.get("build") == provenance.get("build")
                and metadata.get("bundleIdentifier") == provenance.get("bundleIdentifier")
                and metadata.get("builtAtUTC") == provenance.get("builtAtUTC")
            )
            metadata_trust_claims = (
                metadata.get("hardenedRuntime") is True
                and metadata.get("notarized") is True
                and metadata.get("audioInputEntitlement") is True
                and safe_text(metadata.get("signingIdentity"), 256)
                and str(metadata.get("signingIdentity")).startswith(
                    "Developer ID Application:"
                )
            )
            provenance_valid = (
                provenance.get("formatVersion") == 1
                and provenance.get("kind") == RELEASE_PROVENANCE_KIND
                and metadata.get("formatVersion") == 1
                and metadata.get("kind") == RELEASE_METADATA_KIND
                and metadata.get("signedProvenanceResource")
                == str(RELEASE_PROVENANCE_RELATIVE_PATH)
                and metadata.get("appBinarySHA256") == binary_sha
                and metadata.get("signedProvenanceSHA256") == provenance_sha
                and source_matches
                and identity_matches
                and metadata_trust_claims
            )
            if provenance_valid:
                self.build_metadata = metadata
            else:
                provenance_error = "signed provenance or build metadata does not match this app and source commit"
        except (KeyError, TypeError, ValueError, OSError) as error:
            provenance_error = f"release provenance rejected: {error}"
        passed = (
            exists
            and signed
            and stapled
            and gatekeeper
            and signature_contract
            and provenance_valid
        )
        if passed:
            summary = "signed, notarized app is bound to published source and release metadata"
        elif exists and signed and stapled and gatekeeper and not signature_contract:
            summary = signature_summary
        elif provenance_error:
            summary = provenance_error
        else:
            summary = "app is missing or lacks production signature/notarization"
        self.add(
            "app.signed-notarized-release",
            "application",
            passed,
            summary,
            "Run scripts/build-notarized-release.sh and supply its untouched app plus build-metadata.json from the same release directory.",
        )

    def audit_inventory(self) -> None:
        path = self.args.inventory
        if path is None:
            self.add(
                "audio.production-route-inventory",
                "audio",
                False,
                "Core Audio inventory was not supplied",
                "Run --write-device-inventory with the selected input and output UIDs, then pass --inventory.",
            )
            return
        try:
            inventory = load_document(path)
            generated = dt.datetime.fromisoformat(str(inventory["generatedAt"]).replace("Z", "+00:00"))
            age = (self.now - generated).total_seconds()
            if age < -300 or age > self.args.max_inventory_age_hours * 3_600:
                raise ValueError("inventory is stale or future-dated")
            if inventory.get("expectedInputChannels") != self.args.expected_inputs:
                raise ValueError("inventory expected-input count does not match the audit")
            production_inputs = inventory.get("productionReadyInputUIDs")
            production_outputs = inventory.get("productionReadyOutputUIDs")
            simulated = inventory.get("simulatedDeviceUIDs")
            selected_input = inventory.get("selectedInputUID")
            selected_output = inventory.get("selectedOutputUID")
            if not all(isinstance(value, list) for value in (production_inputs, production_outputs, simulated)):
                raise ValueError("inventory production/simulation fields are missing")
            passed = (
                bool(production_inputs)
                and bool(production_outputs)
                and selected_input in production_inputs
                and selected_output in production_outputs
                and selected_input not in simulated
                and selected_output not in simulated
            )
            self.inventory = inventory
            summary = (
                f"selected production route {selected_input} → {selected_output}"
                if passed
                else f"{len(production_inputs)} production input and {len(production_outputs)} production output candidates"
            )
            self.add(
                "audio.production-route-inventory",
                "audio",
                passed,
                summary,
                "Attach/activate the real 64-channel 96 kHz Dante input and an isolated 96 kHz stream output, then regenerate inventory with both selected UIDs.",
            )
        except (KeyError, TypeError, ValueError, OSError) as error:
            self.add(
                "audio.production-route-inventory",
                "audio",
                False,
                f"inventory rejected: {error}",
                "Regenerate the inventory with the current signed app and selected production UIDs.",
            )

    def audit_preflight(self) -> None:
        path = self.args.preflight
        if path is None:
            self.add(
                "audio.route-preflight",
                "audio",
                False,
                "Core Audio preflight was not supplied",
                "Run --core-audio-preflight against the selected production route and venue profile.",
            )
            return
        try:
            artifact = load_document(path)
            report = artifact.get("report")
            if not isinstance(report, dict):
                raise ValueError("wrapped preflight report is missing")
            generated = dt.datetime.fromisoformat(
                str(artifact["generatedAt"]).replace("Z", "+00:00")
            )
            age = (self.now - generated).total_seconds()
            if age < -300 or age > self.args.max_inventory_age_hours * 3_600:
                raise ValueError("preflight is stale or future-dated")
            passed = (
                artifact.get("validationSource") == "core-audio-device"
                and report.get("isReady") is True
                and artifact.get("expectedInputChannels") == self.args.expected_inputs
            )
            if self.inventory is not None:
                passed = (
                    passed
                    and artifact.get("inputDevice", {}).get("uid") == self.inventory.get("selectedInputUID")
                    and artifact.get("outputDevice", {}).get("uid") == self.inventory.get("selectedOutputUID")
                )
            self.preflight = artifact
            self.add(
                "audio.route-preflight",
                "audio",
                passed,
                str(report.get("summary", "preflight not ready")),
                "Resolve every blocking route, clock, format, map, role, stereo-link, override, and output-isolation check.",
            )
        except (KeyError, TypeError, ValueError, OSError) as error:
            self.add(
                "audio.route-preflight",
                "audio",
                False,
                f"preflight rejected: {error}",
                "Regenerate preflight from the current production route and venue profile.",
            )

    def audit_profile(self) -> None:
        path = self.args.profile
        if path is None:
            self.add(
                "profile.production-settings",
                "configuration",
                False,
                "venue profile was not supplied",
                "Save the reviewed venue profile and pass --profile.",
            )
            return
        try:
            profile = load_document(path)
            self.profile = profile
            expected_hours = self.args.duration_seconds / 3_600
            route_matches = self.inventory is not None and (
                profile.get("inputDeviceUID") == self.inventory.get("selectedInputUID")
                and profile.get("outputDeviceUID") == self.inventory.get("selectedOutputUID")
            )
            common = (
                route_matches
                and profile.get("expectedInputChannels") == self.args.expected_inputs
                and float(profile.get("expectedSampleRate", 0)) == self.args.sample_rate
                and profile.get("automaticContinuousRecordingEnabled") is True
                and float(profile.get("plannedRecordingDurationHours", 0)) >= expected_hours
                and float(profile.get("recordingMinimumReserveGB", 0)) >= self.args.reserve_gib
            )
            phase_ready = profile.get("shadowMode") is True if self.args.phase == "sermon" else True
            passed = common and phase_ready
            self.add(
                "profile.production-settings",
                "configuration",
                passed,
                f"{self.args.phase} profile matches route, duration, recording, and rollout policy" if passed else "profile does not match production route or proof policy",
                "Review route UIDs, 64×96 kHz settings, continuous recording, proof duration/reserve, and SHADOW-first sermon policy.",
            )
        except (TypeError, ValueError, OSError) as error:
            self.add(
                "profile.production-settings",
                "configuration",
                False,
                f"profile rejected: {error}",
                "Save a valid AutoMix venue profile and re-run the audit.",
            )

    def audit_storage(self) -> None:
        root = self.args.recording_root
        required_bytes = math.ceil(
            (self.args.expected_inputs + 2)
            * self.args.sample_rate
            * 4
            * self.args.duration_seconds
            + self.args.reserve_gib * 1024**3
        )
        if root is None or not root.is_dir() or root.is_symlink():
            self.add(
                "storage.proof-window-capacity",
                "storage",
                False,
                f"recording volume missing; {required_bytes / 1024**3:.1f} GiB required",
                "Attach a dedicated recording volume and pass --recording-root.",
            )
            return
        stats = os.statvfs(root)
        free_bytes = stats.f_bavail * stats.f_frsize
        passed = free_bytes >= required_bytes and os.access(root, os.W_OK)
        self.add(
            "storage.proof-window-capacity",
            "storage",
            passed,
            f"{free_bytes / 1024**3:.1f} GiB free; {required_bytes / 1024**3:.1f} GiB required",
            "Provide enough writable free space for raw 64-channel plus program capture and the configured reserve.",
        )

    def audit_pco(self) -> None:
        passed = run_quiet(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                PCO_KEYCHAIN_SERVICE,
                "-a",
                "default",
            ]
        )
        self.add(
            "planning-center.credentials",
            "integration",
            passed,
            "Planning Center credentials exist in macOS Keychain" if passed else "Planning Center credentials are not present",
            "Save the venue Personal Access Token credentials in AutoMix and exercise the real service plan.",
        )

    def audit_relaunch(self) -> None:
        app = self.args.app
        plist_path = self.args.home / "Library" / "LaunchAgents" / f"{AUTOMIX_LAUNCH_LABEL}.plist"
        configured = False
        try:
            plist = load_document(plist_path)
            arguments = plist.get("ProgramArguments")
            expected_binary = app / "Contents" / "MacOS" / "AutoMix Native" if app else None
            configured = (
                plist.get("Label") == AUTOMIX_LAUNCH_LABEL
                and plist.get("RunAtLoad") is True
                and isinstance(arguments, list)
                and len(arguments) == 1
                and expected_binary is not None
                and isinstance(arguments[0], str)
                and Path(arguments[0]).resolve() == expected_binary.resolve()
            )
        except (TypeError, ValueError, OSError):
            configured = False
        loaded = run_quiet(
            ["/bin/launchctl", "print", f"gui/{os.getuid()}/{AUTOMIX_LAUNCH_LABEL}"]
        )
        passed = configured and loaded
        self.add(
            "runtime.crash-relaunch-agent",
            "runtime",
            passed,
            "signed app relaunch agent is installed and loaded" if passed else "AutoMix crash relaunch is not installed for this app",
            "Run scripts/install-automix-launch-agent.sh against the permanent notarized app path.",
        )

    def audit_failover(self) -> None:
        path = self.args.failover_readiness
        if path is None:
            self.add(
                "failover.independent-controller",
                "failover",
                False,
                "independent controller readiness was not supplied",
                "Run failover/audit_failover_controller.py on the separate controller, copy its fresh report to this Mac, and pass --failover-readiness.",
            )
            return
        try:
            report = validate_failover_controller_readiness(
                path,
                self.args.repo,
                self.now_ms,
            )
            self.failover_readiness = report
            self.add(
                "failover.independent-controller",
                "failover",
                True,
                (
                    f"separate controller {report['controllerHostname']} is "
                    "running and the relay confirmed backup"
                ),
                "Keep the controller online and latched to backup until the proof starts.",
            )
        except (KeyError, OSError, TypeError, ValueError) as error:
            self.add(
                "failover.independent-controller",
                "failover",
                False,
                f"independent controller readiness rejected: {error}",
                "Regenerate the readiness report on the separate controller with the exact published supervisor package.",
            )

    def audit_obs(self) -> None:
        app = self.args.obs_app
        plugin = app / "Contents" / "PlugIns" / "obs-websocket.plugin"
        installed = (
            app.is_dir()
            and plugin.is_dir()
            and run_quiet(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
            and run_quiet(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])
        )
        self.add(
            "encoder.obs-install",
            "encoder",
            installed,
            "OBS and bundled WebSocket plugin are signed and Gatekeeper-accepted" if installed else "OBS or its WebSocket plugin is missing/untrusted",
            "Install a signed OBS Studio build with the bundled WebSocket plugin.",
        )
        url = self.profile.get("encoderHealthURL") if self.profile else None
        valid_url, public_summary = exact_health_url(url, "encoder")
        passed = False
        summary = public_summary
        if valid_url and not self.args.skip_network_probes:
            try:
                payload = fetch_json(str(url), self.args.network_timeout)
                passed, summary = healthy_observer(payload, "encoder", self.now_ms)
            except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError) as error:
                summary = f"encoder health probe failed: {type(error).__name__}"
        elif valid_url:
            summary = "encoder URL is valid but live probe was skipped"
        self.add(
            "encoder.exact-program-observer",
            "encoder",
            passed,
            summary,
            "Install/configure the OBS health bridge, select the exact stream input/track, start streaming, and verify /health.",
        )

    def audit_egress(self) -> None:
        url = self.profile.get("egressHealthURL") if self.profile else None
        valid_url, public_summary = exact_health_url(url, "egress")
        passed = False
        summary = public_summary
        if valid_url and not self.args.skip_network_probes:
            try:
                payload = fetch_json(str(url), self.args.network_timeout)
                passed, summary = healthy_observer(payload, "egress", self.now_ms)
            except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError) as error:
                summary = f"public-egress health probe failed: {type(error).__name__}"
        elif valid_url:
            summary = "egress URL is valid but live probe was skipped"
        self.add(
            "egress.remote-playback-observer",
            "egress",
            passed,
            summary,
            "Deploy the HLS observer offsite, configure its VPN-protected /health URL, and start a real public stream.",
        )

    def run(self) -> dict[str, Any]:
        self.audit_source()
        self.audit_app()
        self.audit_inventory()
        self.audit_preflight()
        self.audit_profile()
        self.audit_storage()
        self.audit_pco()
        self.audit_relaunch()
        self.audit_failover()
        self.audit_obs()
        self.audit_egress()
        failed = [check for check in self.checks if not check.passed]
        input_paths: dict[str, Path | None] = {
            "buildMetadata": self.args.build_metadata,
            "inventory": self.args.inventory,
            "preflight": self.args.preflight,
            "profile": self.args.profile,
            "failoverReadiness": self.args.failover_readiness,
        }
        evidence_hashes: dict[str, str | None] = {}
        for label, path in input_paths.items():
            try:
                evidence_hashes[label] = hash_file(path) if path is not None else None
            except (OSError, ValueError):
                evidence_hashes[label] = None
        app_binary = (
            self.args.app / "Contents" / "MacOS" / "AutoMix Native"
            if self.args.app is not None
            else None
        )
        try:
            app_binary_sha = hash_file(app_binary) if app_binary is not None else None
        except (OSError, ValueError):
            app_binary_sha = None
        return {
            "formatVersion": FORMAT_VERSION,
            "kind": KIND,
            "generatedAt": self.now.isoformat().replace("+00:00", "Z"),
            "phase": self.args.phase,
            "scope": "production Mac and proof-run prerequisites",
            "readyForHardwareProofRun": not failed,
            "notProductionAcceptance": True,
            "requirements": {
                "expectedInputChannels": self.args.expected_inputs,
                "sampleRate": self.args.sample_rate,
                "durationSeconds": self.args.duration_seconds,
                "recordingReserveGiB": self.args.reserve_gib,
            },
            "inputs": {
                "repoPath": str(self.args.repo.resolve()),
                "sourceCommit": self.source_commit,
                "appPath": str(self.args.app.resolve()) if self.args.app is not None else None,
                "appBinarySHA256": app_binary_sha,
                "buildMetadataPath": str(self.args.build_metadata.resolve()) if self.args.build_metadata is not None else None,
                "buildMetadataSHA256": evidence_hashes["buildMetadata"],
                "obsAppPath": str(self.args.obs_app.resolve()),
                "inventoryPath": str(self.args.inventory.resolve()) if self.args.inventory is not None else None,
                "inventorySHA256": evidence_hashes["inventory"],
                "preflightPath": str(self.args.preflight.resolve()) if self.args.preflight is not None else None,
                "preflightSHA256": evidence_hashes["preflight"],
                "profilePath": str(self.args.profile.resolve()) if self.args.profile is not None else None,
                "profileSHA256": evidence_hashes["profile"],
                "failoverReadinessPath": str(self.args.failover_readiness.resolve()) if self.args.failover_readiness is not None else None,
                "failoverReadinessSHA256": evidence_hashes["failoverReadiness"],
                "recordingRoot": str(self.args.recording_root.resolve()) if self.args.recording_root is not None else None,
            },
            "summary": {
                "passed": len(self.checks) - len(failed),
                "failed": len(failed),
                "total": len(self.checks),
            },
            "checks": [asdict(check) for check in self.checks],
            "remainingAcceptanceScope": [
                "external normally-deenergized failover and physical kill tests",
                "measured camera-to-public-playback lip sync and drift",
                "continuous two-hour zero-xrun hardware evidence",
                "supervised sermon review and signed approval",
                "worship comparison, supervised service, and signed approval",
            ],
        }


def verify_report(path: Path, home: Path | None = None, now: dt.datetime | None = None) -> dict[str, Any]:
    report = load_document(path)
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError("readiness report permissions must be owner-only")
    observed_now = now or utc_now()
    try:
        generated = dt.datetime.fromisoformat(str(report["generatedAt"]).replace("Z", "+00:00"))
        age = (observed_now - generated).total_seconds()
        checks = report["checks"]
        requirements = report["requirements"]
        inputs = report["inputs"]
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("readiness report structure is invalid") from error
    if not isinstance(checks, list) or not isinstance(requirements, dict) or not isinstance(inputs, dict):
        raise ValueError("readiness report structure is invalid")
    if age < -300 or age > 900:
        raise ValueError("readiness report is older than 15 minutes or future-dated")
    check_ids = {item.get("id") for item in checks if isinstance(item, dict)}
    production_requirements = (
        requirements.get("expectedInputChannels") == 64
        and requirements.get("sampleRate") == 96_000
        and isinstance(requirements.get("durationSeconds"), int)
        and not isinstance(requirements.get("durationSeconds"), bool)
        and requirements["durationSeconds"] >= 7_200
        and isinstance(requirements.get("recordingReserveGiB"), (int, float))
        and not isinstance(requirements.get("recordingReserveGiB"), bool)
        and requirements["recordingReserveGiB"] >= 5
    )
    if (
        report.get("formatVersion") != FORMAT_VERSION
        or report.get("kind") != KIND
        or report.get("phase") not in {"sermon", "worship"}
        or report.get("readyForHardwareProofRun") is not True
        or report.get("notProductionAcceptance") is not True
        or not production_requirements
        or check_ids != EXPECTED_CHECK_IDS
        or len(checks) != len(EXPECTED_CHECK_IDS)
        or not all(isinstance(item, dict) and item.get("passed") is True for item in checks)
        or report.get("summary") != {
            "passed": len(EXPECTED_CHECK_IDS),
            "failed": 0,
            "total": len(EXPECTED_CHECK_IDS),
        }
    ):
        raise ValueError("readiness report is incomplete, blocked, or internally inconsistent")
    required_input_fields = (
        "repoPath",
        "sourceCommit",
        "appPath",
        "appBinarySHA256",
        "buildMetadataPath",
        "buildMetadataSHA256",
        "obsAppPath",
        "inventoryPath",
        "inventorySHA256",
        "preflightPath",
        "preflightSHA256",
        "profilePath",
        "profileSHA256",
        "failoverReadinessPath",
        "failoverReadinessSHA256",
        "recordingRoot",
    )
    if any(not isinstance(inputs.get(field), str) or not inputs[field] for field in required_input_fields):
        raise ValueError("readiness report input bindings are incomplete")
    current_commit = git_commit(Path(inputs["repoPath"]))
    if current_commit != inputs["sourceCommit"]:
        raise ValueError("source commit no longer matches readiness report")
    bound_files = (
        (Path(inputs["appPath"]) / "Contents" / "MacOS" / "AutoMix Native", inputs["appBinarySHA256"]),
        (Path(inputs["buildMetadataPath"]), inputs["buildMetadataSHA256"]),
        (Path(inputs["inventoryPath"]), inputs["inventorySHA256"]),
        (Path(inputs["preflightPath"]), inputs["preflightSHA256"]),
        (Path(inputs["profilePath"]), inputs["profileSHA256"]),
        (
            Path(inputs["failoverReadinessPath"]),
            inputs["failoverReadinessSHA256"],
        ),
    )
    for bound_path, expected_hash in bound_files:
        if hash_file(bound_path) != expected_hash:
            raise ValueError(f"bound readiness input changed: {bound_path.name}")
    reconstructed = argparse.Namespace(
        phase=report["phase"],
        repo=Path(inputs["repoPath"]),
        home=home or Path.home(),
        app=Path(inputs["appPath"]),
        build_metadata=Path(inputs["buildMetadataPath"]),
        obs_app=Path(inputs["obsAppPath"]),
        inventory=Path(inputs["inventoryPath"]),
        preflight=Path(inputs["preflightPath"]),
        profile=Path(inputs["profilePath"]),
        failover_readiness=Path(inputs["failoverReadinessPath"]),
        recording_root=Path(inputs["recordingRoot"]),
        expected_inputs=int(requirements["expectedInputChannels"]),
        sample_rate=int(requirements["sampleRate"]),
        duration_seconds=int(requirements["durationSeconds"]),
        reserve_gib=float(requirements["recordingReserveGiB"]),
        max_inventory_age_hours=24.0,
        network_timeout=3.0,
        skip_network_probes=False,
        output=None,
        replace=False,
    )
    rerun = Auditor(reconstructed, now=observed_now).run()
    if not rerun["readyForHardwareProofRun"]:
        blocked = ", ".join(
            item["id"] for item in rerun["checks"] if not item["passed"]
        )
        raise ValueError(f"host is no longer ready: {blocked}")
    return rerun


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Audit whether this Mac is provisioned to begin a real AutoMix hardware-proof run. "
            "This never substitutes for hardware or supervised-live acceptance."
        )
    )
    parser.add_argument("--phase", choices=("sermon", "worship"), default="sermon")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--build-metadata", type=Path)
    parser.add_argument("--obs-app", type=Path, default=Path("/Applications/OBS.app"))
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--preflight", type=Path)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--failover-readiness", type=Path)
    parser.add_argument("--recording-root", type=Path)
    parser.add_argument("--expected-inputs", type=int, default=64)
    parser.add_argument("--sample-rate", type=int, default=96_000)
    parser.add_argument("--duration-seconds", type=int, default=7_200)
    parser.add_argument("--reserve-gib", type=float, default=20)
    parser.add_argument("--max-inventory-age-hours", type=float, default=24)
    parser.add_argument("--network-timeout", type=float, default=3)
    parser.add_argument("--skip-network-probes", action="store_true")
    output_mode = parser.add_mutually_exclusive_group(required=True)
    output_mode.add_argument("--output", type=Path)
    output_mode.add_argument("--verify-report", type=Path)
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args(argv)
    if args.expected_inputs != 64 or args.sample_rate != 96_000:
        parser.error("production readiness requires exactly 64 inputs at 96 kHz")
    if args.duration_seconds < 7_200:
        parser.error("production readiness requires at least 7200 seconds")
    if args.reserve_gib < 5:
        parser.error("recording reserve must be at least 5 GiB")
    if args.max_inventory_age_hours <= 0 or args.network_timeout <= 0:
        parser.error("age and timeout values must be positive")
    return args


def write_report(path: Path, report: dict[str, Any], replace: bool) -> None:
    if path.exists() and not replace:
        raise FileExistsError(f"refusing to overwrite {path}; pass --replace")
    if path.is_symlink():
        raise ValueError("output must not be a symlink")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    finally:
        if temporary.exists():
            temporary.unlink()


def main(argv: list[str] | None = None) -> int:
    args = parse_arguments(argv if argv is not None else sys.argv[1:])
    if args.verify_report is not None:
        try:
            verify_report(args.verify_report)
        except (OSError, ValueError) as error:
            print(f"production host readiness verification failed: {error}", file=sys.stderr)
            return 1
        print(f"Production host readiness verified: {args.verify_report}")
        return 0
    report = Auditor(args).run()
    try:
        write_report(args.output, report, args.replace)
    except (OSError, ValueError) as error:
        print(f"readiness report failed: {error}", file=sys.stderr)
        return 2
    summary = report["summary"]
    print(
        f"Production host readiness: ready={str(report['readyForHardwareProofRun']).lower()} "
        f"passed={summary['passed']} failed={summary['failed']} report={args.output}"
    )
    for check in report["checks"]:
        if not check["passed"]:
            print(f"BLOCKED {check['id']}: {check['summary']}")
    return 0 if report["readyForHardwareProofRun"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
