#!/usr/bin/env python3
"""Independent, fail-closed AutoMix primary/backup supervisor.

This process belongs on a controller that does not share power or an operating
system with the AutoMix Mac.  It consumes AutoMix's read-only /health endpoint
and drives a normally-backup relay through a short primary lease.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import signal
import socket
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple


FORMAT_VERSION = 1
HEARTBEAT_KIND = "automix-primary-audio-heartbeat"
RELAY_COMMAND_KIND = "automix-failover-selection"
RELAY_ACK_KIND = "automix-failover-selection-ack"
STATUS_KIND = "automix-failover-supervisor-status"
CONTROL_KIND = "automix-failover-operator-command"
CONTROL_RESULT_KIND = "automix-failover-operator-result"
MAX_HTTP_BODY_BYTES = 64 * 1024
MAX_CONTROL_BODY_BYTES = 4 * 1024
MAX_SIGNED_TIMESTAMP_MS = (1 << 63) - 1


def epoch_ms() -> int:
    return int(time.time() * 1000.0)


class ConfigurationError(ValueError):
    pass


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """A redirect must never move a safety probe or relay command elsewhere."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        raise urllib.error.HTTPError(
            req.full_url, code, "redirects are not permitted", headers, fp
        )


def validate_endpoint_url(value: str, label: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in ("http", "https"):
        raise ConfigurationError(f"{label} must use http or https")
    if not parsed.hostname:
        raise ConfigurationError(f"{label} must include a host")
    if parsed.username is not None or parsed.password is not None:
        raise ConfigurationError(f"{label} must not contain credentials")
    if parsed.fragment:
        raise ConfigurationError(f"{label} must not contain a fragment")
    return value


def require_range(
    value: float, minimum: float, maximum: float, label: str
) -> float:
    if not math.isfinite(value) or value < minimum or value > maximum:
        raise ConfigurationError(
            f"{label} must be between {minimum:g} and {maximum:g}"
        )
    return value


def validate_timing_budget(
    poll_interval_ms: int,
    heartbeat_timeout_ms: int,
    relay_timeout_ms: int,
    primary_lease_ms: int,
) -> None:
    worst_case_renewal_ms = (
        poll_interval_ms + heartbeat_timeout_ms + relay_timeout_ms
    )
    if worst_case_renewal_ms >= primary_lease_ms:
        raise ConfigurationError(
            "poll interval + heartbeat timeout + relay timeout must be shorter "
            "than the primary lease"
        )


def build_direct_opener() -> Any:
    # Safety traffic must not inherit ambient HTTP(S)_PROXY settings.
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirectHandler()
    )


@dataclass(frozen=True)
class HeartbeatObservation:
    valid: bool
    reason: str
    timestamp_ms: Optional[int] = None


class HeartbeatValidator:
    def __init__(
        self,
        maximum_age_ms: int = 1000,
        maximum_future_skew_ms: int = 250,
        maximum_callback_age_ms: float = 1000.0,
    ) -> None:
        self.maximum_age_ms = maximum_age_ms
        self.maximum_future_skew_ms = maximum_future_skew_ms
        self.maximum_callback_age_ms = maximum_callback_age_ms
        self.last_timestamp_ms: Optional[int] = None

    def reject(self, reason: str) -> HeartbeatObservation:
        # Recovery requires a new baseline followed by advancing samples.
        self.last_timestamp_ms = None
        return HeartbeatObservation(False, reason)

    def evaluate(
        self, http_status: int, body: bytes, observed_at_ms: int
    ) -> HeartbeatObservation:
        if http_status != 200:
            return self.reject(f"heartbeat HTTP status {http_status}")
        if len(body) > MAX_HTTP_BODY_BYTES:
            return self.reject("heartbeat response exceeds 64 KiB")
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return self.reject("heartbeat response is not valid UTF-8 JSON")
        if not isinstance(payload, dict):
            return self.reject("heartbeat payload must be a JSON object")
        format_version = payload.get("formatVersion")
        if (
            not isinstance(format_version, int)
            or isinstance(format_version, bool)
            or format_version != FORMAT_VERSION
        ):
            return self.reject("heartbeat formatVersion is unsupported")
        if payload.get("kind") != HEARTBEAT_KIND:
            return self.reject("heartbeat kind is unsupported")

        required_true = (
            "ok",
            "healthy",
            "streaming",
            "audioActive",
            "engineRunning",
            "routeHealthy",
            "manualReturnRequired",
        )
        for field in required_true:
            if payload.get(field) is not True:
                return self.reject(f"heartbeat {field} is not true")

        timestamp_ms = payload.get("timestampMs")
        if (
            not isinstance(timestamp_ms, int)
            or isinstance(timestamp_ms, bool)
            or timestamp_ms <= 0
            or timestamp_ms > MAX_SIGNED_TIMESTAMP_MS
        ):
            return self.reject("heartbeat timestampMs is invalid")
        age_ms = observed_at_ms - timestamp_ms
        if age_ms > self.maximum_age_ms:
            return self.reject("heartbeat timestamp is stale")
        if age_ms < -self.maximum_future_skew_ms:
            return self.reject("heartbeat timestamp is too far in the future")

        for field in ("inputCallbackAgeMs", "outputCallbackAgeMs"):
            callback_age = payload.get(field)
            if (
                not isinstance(callback_age, (int, float))
                or isinstance(callback_age, bool)
                or not math.isfinite(float(callback_age))
                or float(callback_age) < 0.0
                or float(callback_age) >= self.maximum_callback_age_ms
            ):
                return self.reject(f"heartbeat {field} is invalid or stalled")

        if self.last_timestamp_ms is not None and timestamp_ms <= self.last_timestamp_ms:
            return self.reject("heartbeat timestamp stopped advancing")
        self.last_timestamp_ms = timestamp_ms
        return HeartbeatObservation(True, "primary heartbeat healthy", timestamp_ms)


class HeartbeatClient:
    def __init__(
        self,
        url: str,
        timeout_seconds: float = 0.5,
        validator: Optional[HeartbeatValidator] = None,
        opener: Optional[Any] = None,
    ) -> None:
        self.url = validate_endpoint_url(url, "heartbeat URL")
        self.timeout_seconds = require_range(
            timeout_seconds, 0.05, 1.0, "heartbeat timeout"
        )
        self.validator = validator or HeartbeatValidator()
        self.opener = opener or build_direct_opener()

    def fetch(self, observed_at_ms: Optional[int] = None) -> HeartbeatObservation:
        request = urllib.request.Request(
            self.url,
            method="GET",
            headers={
                "Accept": "application/json",
                "Cache-Control": "no-cache, no-store",
                "User-Agent": "AutoMixFailoverSupervisor/1",
            },
        )
        try:
            with self.opener.open(request, timeout=self.timeout_seconds) as response:
                body = response.read(MAX_HTTP_BODY_BYTES + 1)
                checked_at_ms = (
                    epoch_ms() if observed_at_ms is None else observed_at_ms
                )
                return self.validator.evaluate(
                    int(response.status), body, checked_at_ms
                )
        except urllib.error.HTTPError as error:
            return self.validator.reject(f"heartbeat HTTP status {error.code}")
        except Exception as error:
            return self.validator.reject(
                f"heartbeat unavailable ({error.__class__.__name__})"
            )


@dataclass(frozen=True)
class RelayResult:
    ok: bool
    reason: str
    selected_input: str
    request_id: str


class RelayClient:
    def __init__(
        self,
        url: str,
        lease_ms: int = 1500,
        timeout_seconds: float = 0.5,
        bearer_token_file: Optional[Path] = None,
        opener: Optional[Any] = None,
    ) -> None:
        self.url = validate_endpoint_url(url, "relay URL")
        if lease_ms < 500 or lease_ms > 1500:
            raise ConfigurationError("primary lease must be between 500 and 1500 ms")
        self.lease_ms = lease_ms
        self.timeout_seconds = require_range(
            timeout_seconds, 0.05, 1.0, "relay timeout"
        )
        if self.timeout_seconds * 1000.0 >= float(self.lease_ms):
            raise ConfigurationError(
                "relay timeout must be shorter than the primary lease"
            )
        self.bearer_token_file = bearer_token_file
        self.opener = opener or build_direct_opener()

    def _bearer_token(self) -> Optional[str]:
        if self.bearer_token_file is None:
            return None
        path = self.bearer_token_file
        flags = os.O_RDONLY
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode):
                raise ConfigurationError(
                    "relay bearer token path must be a regular file"
                )
            if info.st_mode & 0o077:
                raise ConfigurationError(
                    "relay bearer token file must not be group/world accessible"
                )
            if info.st_size > 4097:
                raise ConfigurationError("relay bearer token file is invalid")
            with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
                descriptor = -1
                token = stream.read(4097).strip()
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        if not token or len(token) > 4096 or "\n" in token or "\r" in token:
            raise ConfigurationError("relay bearer token file is invalid")
        return token

    def select(
        self, selected_input: str, reason: str, issued_at_ms: Optional[int] = None
    ) -> RelayResult:
        if selected_input not in ("primary", "backup"):
            raise ValueError("selected_input must be primary or backup")
        request_id = str(uuid.uuid4())
        command = {
            "formatVersion": FORMAT_VERSION,
            "kind": RELAY_COMMAND_KIND,
            "requestId": request_id,
            "issuedAtMs": epoch_ms() if issued_at_ms is None else issued_at_ms,
            "selectedInput": selected_input,
            "leaseMs": self.lease_ms if selected_input == "primary" else 0,
            "latch": selected_input == "backup",
            "manualReturnRequired": True,
            "reason": reason[:512],
        }
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
            "User-Agent": "AutoMixFailoverSupervisor/1",
        }
        try:
            token = self._bearer_token()
            if token is not None:
                headers["Authorization"] = f"Bearer {token}"
            body = json.dumps(
                command, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
            request = urllib.request.Request(
                self.url, data=body, method="POST", headers=headers
            )
            with self.opener.open(request, timeout=self.timeout_seconds) as response:
                response_body = response.read(MAX_HTTP_BODY_BYTES + 1)
                status_code = int(response.status)
        except Exception as error:
            return RelayResult(
                False,
                f"relay unavailable ({error.__class__.__name__})",
                selected_input,
                request_id,
            )

        if status_code < 200 or status_code >= 300:
            return RelayResult(
                False,
                f"relay HTTP status {status_code}",
                selected_input,
                request_id,
            )
        if len(response_body) > MAX_HTTP_BODY_BYTES:
            return RelayResult(
                False, "relay response exceeds 64 KiB", selected_input, request_id
            )
        try:
            acknowledgement = json.loads(response_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return RelayResult(
                False, "relay acknowledgement is not valid JSON", selected_input, request_id
            )
        expected_latch = selected_input == "backup"
        acknowledgement_version = (
            acknowledgement.get("formatVersion")
            if isinstance(acknowledgement, dict)
            else None
        )
        valid = (
            isinstance(acknowledgement, dict)
            and isinstance(acknowledgement_version, int)
            and not isinstance(acknowledgement_version, bool)
            and acknowledgement_version == FORMAT_VERSION
            and acknowledgement.get("kind") == RELAY_ACK_KIND
            and acknowledgement.get("requestId") == request_id
            and acknowledgement.get("ok") is True
            and acknowledgement.get("selectedInput") == selected_input
            and acknowledgement.get("latched") is expected_latch
        )
        if not valid:
            return RelayResult(
                False,
                "relay acknowledgement does not confirm the requested safe state",
                selected_input,
                request_id,
            )
        return RelayResult(
            True, f"relay confirmed {selected_input}", selected_input, request_id
        )


@dataclass
class FailoverState:
    selected_input: str = "backup"
    backup_latched: bool = True
    backup_latched_at_ms: int = 0
    reason: str = "supervisor startup"
    valid_healthy_samples: int = 0
    last_heartbeat_timestamp_ms: Optional[int] = None
    last_healthy_observed_at_ms: Optional[int] = None

    def observe(
        self, observation: HeartbeatObservation, observed_at_ms: int
    ) -> bool:
        previous = (self.selected_input, self.backup_latched, self.reason)
        if observation.valid:
            self.valid_healthy_samples = min(
                self.valid_healthy_samples + 1, 1_000_000
            )
            self.last_heartbeat_timestamp_ms = observation.timestamp_ms
            self.last_healthy_observed_at_ms = observed_at_ms
            if self.selected_input == "primary":
                self.reason = "primary heartbeat healthy"
            else:
                self.reason = "backup latched; explicit operator return required"
        else:
            self.valid_healthy_samples = 0
            self.last_heartbeat_timestamp_ms = None
            self.last_healthy_observed_at_ms = None
            self.selected_input = "backup"
            self.backup_latched = True
            self.backup_latched_at_ms = observed_at_ms
            self.reason = observation.reason
        return previous != (self.selected_input, self.backup_latched, self.reason)

    def can_return_primary(
        self, now_ms: int, required_samples: int, maximum_sample_age_ms: int
    ) -> Tuple[bool, str]:
        if self.selected_input == "primary":
            return True, "primary is already selected"
        if self.valid_healthy_samples < required_samples:
            return (
                False,
                f"need {required_samples} advancing healthy samples; "
                f"have {self.valid_healthy_samples}",
            )
        if self.last_healthy_observed_at_ms is None:
            return False, "no recent healthy heartbeat"
        if now_ms - self.last_healthy_observed_at_ms > maximum_sample_age_ms:
            return False, "healthy heartbeat proof is stale"
        if now_ms < self.last_healthy_observed_at_ms:
            return False, "controller clock moved backward"
        return True, "healthy proof permits an explicit return"

    def mark_primary(self) -> None:
        self.selected_input = "primary"
        self.backup_latched = False
        self.reason = "operator explicitly returned to primary"

    def force_backup(self, reason: str, latched_at_ms: Optional[int] = None) -> None:
        self.selected_input = "backup"
        self.backup_latched = True
        if latched_at_ms is not None:
            self.backup_latched_at_ms = latched_at_ms
        self.reason = reason


class AtomicStatusWriter:
    def __init__(self, path: Path) -> None:
        self.path = path

    def write(self, payload: Dict[str, Any]) -> None:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{self.path.name}.", dir=str(self.path.parent)
        )
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                descriptor = -1
                json.dump(payload, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_name, self.path)
            temporary_name = ""
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            if temporary_name:
                try:
                    os.unlink(temporary_name)
                except FileNotFoundError:
                    pass


class EventJournal:
    def __init__(self, path: Optional[Path]) -> None:
        self.path = path

    def append(self, event: Dict[str, Any]) -> None:
        if self.path is None:
            return
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(
            self.path,
            os.O_APPEND | os.O_CREAT | os.O_WRONLY,
            0o600,
        )
        try:
            os.fchmod(descriptor, 0o600)
            encoded = (
                json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode("utf-8")
            offset = 0
            while offset < len(encoded):
                written = os.write(descriptor, encoded[offset:])
                if written <= 0:
                    raise OSError("event journal write made no progress")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


class FailoverSupervisor:
    def __init__(
        self,
        heartbeat_client: Any,
        relay_client: Any,
        status_writer: Optional[AtomicStatusWriter] = None,
        journal: Optional[EventJournal] = None,
        required_healthy_samples: int = 3,
        maximum_return_sample_age_ms: int = 1000,
        monotonic_clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if required_healthy_samples < 2 or required_healthy_samples > 20:
            raise ConfigurationError(
                "required healthy samples must be between 2 and 20"
            )
        self.heartbeat_client = heartbeat_client
        self.relay_client = relay_client
        self.status_writer = status_writer
        self.journal = journal or EventJournal(None)
        self.required_healthy_samples = required_healthy_samples
        self.maximum_return_sample_age_ms = maximum_return_sample_age_ms
        self.monotonic_clock = monotonic_clock
        self.primary_lease_ms = int(getattr(relay_client, "lease_ms", 1500))
        self.relay_timeout_ms = int(
            round(float(getattr(relay_client, "timeout_seconds", 0.5)) * 1000.0)
        )
        if self.primary_lease_ms < 500 or self.primary_lease_ms > 1500:
            raise ConfigurationError(
                "supervisor requires a primary lease between 500 and 1500 ms"
            )
        if self.relay_timeout_ms < 1 or self.relay_timeout_ms > 1000:
            raise ConfigurationError(
                "supervisor requires a relay timeout no longer than one second"
            )
        if self.relay_timeout_ms >= self.primary_lease_ms:
            raise ConfigurationError(
                "supervisor relay timeout must be shorter than the primary lease"
            )
        self.state = FailoverState()
        self.last_observation = HeartbeatObservation(
            False, "no heartbeat observed since supervisor startup"
        )
        self.last_relay_result = RelayResult(
            False, "relay not contacted", "backup", ""
        )
        self.last_primary_ack_monotonic: Optional[float] = None
        self.updated_at_ms = epoch_ms()

    def _primary_lease_remaining_ms(self) -> int:
        if (
            self.state.selected_input != "primary"
            or self.last_primary_ack_monotonic is None
        ):
            return 0
        elapsed_seconds = self.monotonic_clock() - self.last_primary_ack_monotonic
        if elapsed_seconds < 0.0:
            return 0
        return max(
            0, self.primary_lease_ms - int(round(elapsed_seconds * 1000.0))
        )

    def _primary_lease_can_be_renewed_safely(self) -> bool:
        remaining_ms = self._primary_lease_remaining_ms()
        # Do not begin a request unless its entire configured timeout fits before
        # the old lease expires. A late response must never reassert primary after
        # the relay may already have fallen back.
        return remaining_ms > self.relay_timeout_ms

    def snapshot(self) -> Dict[str, Any]:
        return {
            "formatVersion": FORMAT_VERSION,
            "kind": STATUS_KIND,
            "updatedAtMs": self.updated_at_ms,
            "selectedInput": self.state.selected_input,
            "backupLatched": self.state.backup_latched,
            "backupLatchedAtMs": self.state.backup_latched_at_ms,
            "manualReturnRequired": True,
            "reason": self.state.reason,
            "heartbeatValid": self.last_observation.valid,
            "heartbeatReason": self.last_observation.reason,
            "lastHeartbeatTimestampMs": self.state.last_heartbeat_timestamp_ms,
            "lastHealthyObservedAtMs": self.state.last_healthy_observed_at_ms,
            "validHealthySamples": self.state.valid_healthy_samples,
            "requiredHealthySamples": self.required_healthy_samples,
            "relayConfirmed": self.last_relay_result.ok,
            "relayReason": self.last_relay_result.reason,
            "relayRequestId": self.last_relay_result.request_id,
            "primaryLeaseMs": self.primary_lease_ms,
            "primaryLeaseRemainingMs": self._primary_lease_remaining_ms(),
        }

    def _write_status(self, now_ms: int) -> None:
        self.updated_at_ms = now_ms
        if self.status_writer is not None:
            self.status_writer.write(self.snapshot())

    def _journal(self, event: str, now_ms: int, **fields: Any) -> None:
        payload: Dict[str, Any] = {
            "formatVersion": FORMAT_VERSION,
            "kind": "automix-failover-supervisor-event",
            "event": event,
            "timestampMs": now_ms,
            "selectedInput": self.state.selected_input,
            "reason": self.state.reason,
        }
        payload.update(fields)
        self.journal.append(payload)

    def start(self, now_ms: Optional[int] = None) -> RelayResult:
        checked_at_ms = epoch_ms() if now_ms is None else now_ms
        self.state.force_backup(
            "supervisor startup; backup is mandatory", checked_at_ms
        )
        self.last_primary_ack_monotonic = None
        self.last_relay_result = self.relay_client.select(
            "backup", self.state.reason, checked_at_ms
        )
        self._write_status(checked_at_ms)
        self._journal(
            "startup-backup-command",
            checked_at_ms,
            relayConfirmed=self.last_relay_result.ok,
            relayReason=self.last_relay_result.reason,
        )
        return self.last_relay_result

    def step(self, now_ms: Optional[int] = None) -> Dict[str, Any]:
        previous_input = self.state.selected_input
        if now_ms is None:
            self.last_observation = self.heartbeat_client.fetch()
            checked_at_ms = epoch_ms()
        else:
            checked_at_ms = now_ms
            self.last_observation = self.heartbeat_client.fetch(checked_at_ms)
        self.state.observe(self.last_observation, checked_at_ms)

        desired_input = self.state.selected_input
        if (
            desired_input == "primary"
            and not self._primary_lease_can_be_renewed_safely()
        ):
            self.state.force_backup(
                "primary lease renewal deadline was missed; "
                "explicit operator return is required",
                checked_at_ms,
            )
            self.last_primary_ack_monotonic = None
            desired_input = "backup"
            self._journal("primary-lease-deadline-missed", checked_at_ms)
        self.last_relay_result = self.relay_client.select(
            desired_input, self.state.reason, checked_at_ms
        )
        if desired_input == "primary":
            if self.last_relay_result.ok:
                self.last_primary_ack_monotonic = self.monotonic_clock()
            else:
                relay_failure = self.last_relay_result.reason
                self.state.force_backup(
                    f"primary lease refresh failed: {relay_failure}",
                    checked_at_ms,
                )
                self.last_primary_ack_monotonic = None
                self.last_relay_result = self.relay_client.select(
                    "backup", self.state.reason, checked_at_ms
                )
                self._journal(
                    "primary-lease-failed",
                    checked_at_ms,
                    failure=relay_failure,
                    backupCommandConfirmed=self.last_relay_result.ok,
                )
        else:
            self.last_primary_ack_monotonic = None

        if previous_input == "primary" and self.state.selected_input == "backup":
            self._journal("failover-to-backup", checked_at_ms)
        self._write_status(checked_at_ms)
        return self.snapshot()

    def request_primary_return(
        self,
        now_ms: Optional[int] = None,
        operator_issued_at_ms: Optional[int] = None,
    ) -> Tuple[bool, str]:
        checked_at_ms = epoch_ms() if now_ms is None else now_ms
        issued_at_ms = (
            checked_at_ms
            if operator_issued_at_ms is None
            else operator_issued_at_ms
        )
        if issued_at_ms < self.state.backup_latched_at_ms:
            reason = "operator return request predates the current backup latch"
            self._journal("operator-return-rejected", checked_at_ms, rejection=reason)
            self._write_status(checked_at_ms)
            return False, reason
        if checked_at_ms - issued_at_ms > 5000:
            reason = "operator return request is stale"
            self._journal("operator-return-rejected", checked_at_ms, rejection=reason)
            self._write_status(checked_at_ms)
            return False, reason
        if issued_at_ms - checked_at_ms > 250:
            reason = "operator return request timestamp is in the future"
            self._journal("operator-return-rejected", checked_at_ms, rejection=reason)
            self._write_status(checked_at_ms)
            return False, reason
        allowed, reason = self.state.can_return_primary(
            checked_at_ms,
            self.required_healthy_samples,
            self.maximum_return_sample_age_ms,
        )
        if not allowed:
            self._journal("operator-return-rejected", checked_at_ms, rejection=reason)
            self._write_status(checked_at_ms)
            return False, reason
        if self.state.selected_input == "primary":
            return True, reason

        result = self.relay_client.select(
            "primary", "explicit operator return after renewed health proof", checked_at_ms
        )
        self.last_relay_result = result
        if not result.ok:
            self.state.force_backup(
                f"operator return failed; primary relay not confirmed: {result.reason}",
                checked_at_ms,
            )
            self.last_primary_ack_monotonic = None
            self.last_relay_result = self.relay_client.select(
                "backup", self.state.reason, checked_at_ms
            )
            self._journal(
                "operator-return-failed",
                checked_at_ms,
                failure=result.reason,
                backupCommandConfirmed=self.last_relay_result.ok,
            )
            self._write_status(checked_at_ms)
            return False, result.reason

        self.state.mark_primary()
        self.last_primary_ack_monotonic = self.monotonic_clock()
        self._journal("operator-returned-primary", checked_at_ms)
        self._write_status(checked_at_ms)
        return True, "relay confirmed explicit return to primary"

    def shutdown(self, now_ms: Optional[int] = None) -> RelayResult:
        checked_at_ms = epoch_ms() if now_ms is None else now_ms
        self.state.force_backup(
            "supervisor shutdown; backup is mandatory", checked_at_ms
        )
        self.last_primary_ack_monotonic = None
        self.last_relay_result = self.relay_client.select(
            "backup", self.state.reason, checked_at_ms
        )
        self._write_status(checked_at_ms)
        self._journal(
            "shutdown-backup-command",
            checked_at_ms,
            relayConfirmed=self.last_relay_result.ok,
            relayReason=self.last_relay_result.reason,
        )
        return self.last_relay_result


class OperatorControlServer:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.socket: Optional[socket.socket] = None

    def open(self) -> None:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        if self.path.exists() or self.path.is_socket():
            info = self.path.lstat()
            if not stat.S_ISSOCK(info.st_mode):
                raise ConfigurationError(
                    f"control path exists and is not a socket: {self.path}"
                )
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(0.2)
            try:
                probe.connect(str(self.path))
            except (ConnectionRefusedError, FileNotFoundError):
                self.path.unlink()
            except OSError as error:
                raise ConfigurationError(
                    f"cannot prove existing control socket is stale: {error}"
                ) from error
            else:
                raise ConfigurationError(
                    f"another supervisor is already using {self.path}"
                )
            finally:
                probe.close()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(self.path))
            os.chmod(self.path, 0o600)
            server.listen(4)
            server.setblocking(False)
        except Exception:
            server.close()
            raise
        self.socket = server

    def serve_pending(
        self,
        handler: Callable[[str, int], Tuple[bool, str]],
        limit: int = 8,
    ) -> None:
        if self.socket is None:
            return
        for _ in range(limit):
            try:
                connection, _ = self.socket.accept()
            except BlockingIOError:
                return
            with connection:
                connection.settimeout(0.5)
                response: Dict[str, Any]
                try:
                    body = b""
                    while b"\n" not in body and len(body) <= MAX_CONTROL_BODY_BYTES:
                        chunk = connection.recv(1024)
                        if not chunk:
                            break
                        body += chunk
                    if len(body) > MAX_CONTROL_BODY_BYTES:
                        raise ValueError("operator command exceeds 4 KiB")
                    command = json.loads(body.decode("utf-8"))
                    command_version = (
                        command.get("formatVersion")
                        if isinstance(command, dict)
                        else None
                    )
                    issued_at_ms = (
                        command.get("issuedAtMs")
                        if isinstance(command, dict)
                        else None
                    )
                    request_id = (
                        command.get("requestId")
                        if isinstance(command, dict)
                        else None
                    )
                    if (
                        not isinstance(command, dict)
                        or not isinstance(command_version, int)
                        or isinstance(command_version, bool)
                        or command_version != FORMAT_VERSION
                        or command.get("kind") != CONTROL_KIND
                        or command.get("command") not in ("return-primary", "status")
                        or not isinstance(issued_at_ms, int)
                        or isinstance(issued_at_ms, bool)
                        or issued_at_ms <= 0
                        or issued_at_ms > MAX_SIGNED_TIMESTAMP_MS
                        or not isinstance(request_id, str)
                        or not request_id
                        or len(request_id) > 128
                    ):
                        raise ValueError("operator command contract is invalid")
                    accepted, message = handler(
                        str(command["command"]), issued_at_ms
                    )
                    response = {
                        "formatVersion": FORMAT_VERSION,
                        "kind": CONTROL_RESULT_KIND,
                        "requestId": request_id,
                        "accepted": accepted,
                        "message": message,
                    }
                except Exception as error:
                    response = {
                        "formatVersion": FORMAT_VERSION,
                        "kind": CONTROL_RESULT_KIND,
                        "requestId": "",
                        "accepted": False,
                        "message": str(error),
                    }
                encoded = (
                    json.dumps(response, sort_keys=True, separators=(",", ":")) + "\n"
                ).encode("utf-8")
                try:
                    connection.sendall(encoded)
                except OSError:
                    pass

    def close(self) -> None:
        if self.socket is not None:
            self.socket.close()
            self.socket = None
        try:
            if self.path.is_socket():
                self.path.unlink()
        except FileNotFoundError:
            pass


def send_control_command(
    path: Path, command: str, timeout_seconds: float = 2.0
) -> Dict[str, Any]:
    request = {
        "formatVersion": FORMAT_VERSION,
        "kind": CONTROL_KIND,
        "requestId": str(uuid.uuid4()),
        "issuedAtMs": epoch_ms(),
        "command": command,
    }
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout_seconds)
    try:
        client.connect(str(path))
        client.sendall(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
        body = b""
        while b"\n" not in body and len(body) <= MAX_CONTROL_BODY_BYTES:
            chunk = client.recv(1024)
            if not chunk:
                break
            body += chunk
    finally:
        client.close()
    if len(body) > MAX_CONTROL_BODY_BYTES:
        raise RuntimeError("operator response exceeds 4 KiB")
    response = json.loads(body.decode("utf-8"))
    response_version = (
        response.get("formatVersion") if isinstance(response, dict) else None
    )
    if (
        not isinstance(response, dict)
        or not isinstance(response_version, int)
        or isinstance(response_version, bool)
        or response_version != FORMAT_VERSION
        or response.get("kind") != CONTROL_RESULT_KIND
        or response.get("requestId") != request["requestId"]
        or not isinstance(response.get("accepted"), bool)
        or not isinstance(response.get("message"), str)
    ):
        raise RuntimeError("operator response contract is invalid")
    return response


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fail-closed supervisor for AutoMix primary/backup audio"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    supervise = subparsers.add_parser(
        "supervise", help="poll AutoMix and maintain the relay lease"
    )
    supervise.add_argument("--heartbeat-url", required=True)
    supervise.add_argument("--relay-url", required=True)
    supervise.add_argument(
        "--relay-bearer-token-file", type=Path, default=None
    )
    supervise.add_argument("--poll-interval-ms", type=int, default=250)
    supervise.add_argument("--heartbeat-timeout-ms", type=int, default=500)
    supervise.add_argument("--relay-timeout-ms", type=int, default=500)
    supervise.add_argument("--primary-lease-ms", type=int, default=1500)
    supervise.add_argument("--required-healthy-samples", type=int, default=3)
    supervise.add_argument(
        "--control-socket",
        type=Path,
        default=Path("/var/tmp/automix-failover/control.sock"),
    )
    supervise.add_argument(
        "--status-path",
        type=Path,
        default=Path("/var/tmp/automix-failover/status.json"),
    )
    supervise.add_argument(
        "--journal-path",
        type=Path,
        default=Path("/var/tmp/automix-failover/events.jsonl"),
    )

    return_primary = subparsers.add_parser(
        "return-primary", help="request a deliberate operator return"
    )
    return_primary.add_argument(
        "--control-socket",
        type=Path,
        default=Path("/var/tmp/automix-failover/control.sock"),
    )

    status_parser = subparsers.add_parser(
        "status", help="read the latest supervisor status"
    )
    status_parser.add_argument(
        "--status-path",
        type=Path,
        default=Path("/var/tmp/automix-failover/status.json"),
    )
    return parser


def run_supervisor(arguments: argparse.Namespace) -> int:
    poll_interval_ms = int(
        require_range(
            float(arguments.poll_interval_ms), 100.0, 500.0, "poll interval"
        )
    )
    heartbeat_timeout_ms = int(
        require_range(
            float(arguments.heartbeat_timeout_ms),
            50.0,
            1000.0,
            "heartbeat timeout",
        )
    )
    relay_timeout_ms = int(
        require_range(
            float(arguments.relay_timeout_ms),
            50.0,
            1000.0,
            "relay timeout",
        )
    )
    validate_timing_budget(
        poll_interval_ms,
        heartbeat_timeout_ms,
        relay_timeout_ms,
        arguments.primary_lease_ms,
    )
    heartbeat = HeartbeatClient(
        arguments.heartbeat_url,
        timeout_seconds=float(heartbeat_timeout_ms) / 1000.0,
    )
    relay = RelayClient(
        arguments.relay_url,
        lease_ms=arguments.primary_lease_ms,
        timeout_seconds=float(relay_timeout_ms) / 1000.0,
        bearer_token_file=arguments.relay_bearer_token_file,
    )
    supervisor = FailoverSupervisor(
        heartbeat,
        relay,
        AtomicStatusWriter(arguments.status_path),
        EventJournal(arguments.journal_path),
        required_healthy_samples=arguments.required_healthy_samples,
    )
    control = OperatorControlServer(arguments.control_socket)
    control.open()
    stopping = False

    def stop(_signum: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True

    old_sigint = signal.signal(signal.SIGINT, stop)
    old_sigterm = signal.signal(signal.SIGTERM, stop)
    try:
        supervisor.start()
        while not stopping:
            iteration_started = time.monotonic()
            supervisor.step()

            def handle(command: str, issued_at_ms: int) -> Tuple[bool, str]:
                if command == "return-primary":
                    return supervisor.request_primary_return(
                        operator_issued_at_ms=issued_at_ms
                    )
                return True, json.dumps(
                    supervisor.snapshot(), sort_keys=True, separators=(",", ":")
                )

            control.serve_pending(handle)
            elapsed = time.monotonic() - iteration_started
            remaining = (float(poll_interval_ms) / 1000.0) - elapsed
            if remaining > 0:
                time.sleep(remaining)
    finally:
        try:
            supervisor.shutdown()
        finally:
            control.close()
            signal.signal(signal.SIGINT, old_sigint)
            signal.signal(signal.SIGTERM, old_sigterm)
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_argument_parser()
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "supervise":
            return run_supervisor(arguments)
        if arguments.command == "return-primary":
            response = send_control_command(
                arguments.control_socket, "return-primary"
            )
            print(json.dumps(response, indent=2, sort_keys=True))
            return 0 if response["accepted"] else 2
        if arguments.command == "status":
            payload = json.loads(arguments.status_path.read_text(encoding="utf-8"))
            print(json.dumps(payload, indent=2, sort_keys=True))
            return 0
    except (ConfigurationError, OSError, RuntimeError, json.JSONDecodeError) as error:
        print(f"failover supervisor: {error}", file=sys.stderr)
        return 2
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
