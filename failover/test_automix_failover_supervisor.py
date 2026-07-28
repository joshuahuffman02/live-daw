#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional


sys.path.insert(0, str(Path(__file__).resolve().parent))

from automix_failover_supervisor import (  # noqa: E402
    AtomicStatusWriter,
    ConfigurationError,
    CONTROL_RESULT_KIND,
    EventJournal,
    FailoverState,
    FailoverSupervisor,
    FORMAT_VERSION,
    HEARTBEAT_KIND,
    HeartbeatClient,
    HeartbeatObservation,
    HeartbeatValidator,
    OperatorControlServer,
    RELAY_ACK_KIND,
    RelayClient,
    RelayResult,
    STATUS_KIND,
    send_control_command,
    validate_endpoint_url,
    validate_timing_budget,
)


def healthy_payload(timestamp_ms: int) -> Dict[str, Any]:
    return {
        "formatVersion": FORMAT_VERSION,
        "kind": HEARTBEAT_KIND,
        "ok": True,
        "healthy": True,
        "streaming": True,
        "audioActive": True,
        "timestampMs": timestamp_ms,
        "name": "AutoMix Mac",
        "detail": "primary audio carrier healthy",
        "engineRunning": True,
        "routeHealthy": True,
        "inputCallbackAgeMs": 10.0,
        "outputCallbackAgeMs": 11.0,
        "manualReturnRequired": True,
    }


def observation(timestamp_ms: int) -> HeartbeatObservation:
    return HeartbeatObservation(True, "primary heartbeat healthy", timestamp_ms)


class FakeHeartbeatClient:
    def __init__(self, observations: List[HeartbeatObservation]) -> None:
        self.observations = observations
        self.calls: List[int] = []

    def fetch(
        self, observed_at_ms: Optional[int] = None
    ) -> HeartbeatObservation:
        self.calls.append(observed_at_ms)
        if not self.observations:
            return HeartbeatObservation(False, "fake heartbeat exhausted")
        return self.observations.pop(0)


class FakeRelayClient:
    def __init__(self) -> None:
        self.calls: List[Dict[str, Any]] = []
        self.fail_primary = False
        self.fail_backup = False
        self.lease_ms = 1500
        self.timeout_seconds = 0.5

    def select(
        self, selected_input: str, reason: str, issued_at_ms: int
    ) -> RelayResult:
        self.calls.append(
            {
                "selectedInput": selected_input,
                "reason": reason,
                "issuedAtMs": issued_at_ms,
            }
        )
        failed = (
            selected_input == "primary"
            and self.fail_primary
            or selected_input == "backup"
            and self.fail_backup
        )
        return RelayResult(
            not failed,
            "fake relay failure" if failed else f"relay confirmed {selected_input}",
            selected_input,
            f"request-{len(self.calls)}",
        )


class TestHTTPServer:
    def __init__(
        self,
        get_handler: Optional[
            Callable[[BaseHTTPRequestHandler], None]
        ] = None,
        post_handler: Optional[
            Callable[[BaseHTTPRequestHandler, bytes], None]
        ] = None,
    ) -> None:
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                if get_handler is None:
                    self.send_error(404)
                else:
                    get_handler(self)

            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                outer.requests.append(
                    {
                        "path": self.path,
                        "headers": dict(self.headers),
                        "body": body,
                    }
                )
                if post_handler is None:
                    self.send_error(404)
                else:
                    post_handler(self, body)

            def log_message(self, _format: str, *args: Any) -> None:
                pass

        self.requests: List[Dict[str, Any]] = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=self.server.serve_forever, name="failover-test-http", daemon=True
        )

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_port}"

    def __enter__(self) -> "TestHTTPServer":
        self.thread.start()
        return self

    def __exit__(self, *args: Any) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2.0)


def send_json(
    handler: BaseHTTPRequestHandler, status: int, payload: Dict[str, Any]
) -> None:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class HeartbeatValidatorTests(unittest.TestCase):
    def test_accepts_only_fresh_advancing_complete_heartbeat(self) -> None:
        validator = HeartbeatValidator()
        first = validator.evaluate(
            200, json.dumps(healthy_payload(99_900)).encode(), 100_000
        )
        second = validator.evaluate(
            200, json.dumps(healthy_payload(100_100)).encode(), 100_200
        )
        self.assertTrue(first.valid)
        self.assertTrue(second.valid)
        self.assertEqual(second.timestamp_ms, 100_100)

    def test_rejects_http_contract_and_readiness_failures(self) -> None:
        cases: List[tuple[str, int, Any]] = [
            ("non-200", 503, healthy_payload(100_000)),
            ("not-object", 200, []),
            (
                "wrong-version",
                200,
                {**healthy_payload(100_000), "formatVersion": 2},
            ),
            (
                "boolean-version",
                200,
                {**healthy_payload(100_000), "formatVersion": True},
            ),
            ("wrong-kind", 200, {**healthy_payload(100_000), "kind": "other"}),
            ("not-healthy", 200, {**healthy_payload(100_000), "healthy": False}),
            (
                "no-manual-return",
                200,
                {**healthy_payload(100_000), "manualReturnRequired": False},
            ),
            (
                "stalled-input",
                200,
                {**healthy_payload(100_000), "inputCallbackAgeMs": 1000.0},
            ),
        ]
        for label, status_code, payload in cases:
            with self.subTest(label=label):
                validator = HeartbeatValidator()
                result = validator.evaluate(
                    status_code, json.dumps(payload).encode(), 100_100
                )
                self.assertFalse(result.valid)

    def test_rejects_stale_future_overflow_and_non_advancing_timestamps(self) -> None:
        validator = HeartbeatValidator()
        stale = validator.evaluate(
            200, json.dumps(healthy_payload(98_000)).encode(), 100_000
        )
        future = validator.evaluate(
            200, json.dumps(healthy_payload(101_000)).encode(), 100_000
        )
        overflow = validator.evaluate(
            200, json.dumps(healthy_payload(1 << 63)).encode(), 100_000
        )
        first = validator.evaluate(
            200, json.dumps(healthy_payload(99_900)).encode(), 100_000
        )
        duplicate = validator.evaluate(
            200, json.dumps(healthy_payload(99_900)).encode(), 100_100
        )
        self.assertFalse(stale.valid)
        self.assertFalse(future.valid)
        self.assertFalse(overflow.valid)
        self.assertTrue(first.valid)
        self.assertFalse(duplicate.valid)
        self.assertIn("stopped advancing", duplicate.reason)

    def test_failure_resets_progression_baseline(self) -> None:
        validator = HeartbeatValidator()
        self.assertTrue(
            validator.evaluate(
                200, json.dumps(healthy_payload(99_900)).encode(), 100_000
            ).valid
        )
        self.assertFalse(validator.evaluate(503, b"{}", 100_100).valid)
        recovered_baseline = validator.evaluate(
            200, json.dumps(healthy_payload(99_800)).encode(), 100_200
        )
        recovered_advance = validator.evaluate(
            200, json.dumps(healthy_payload(100_100)).encode(), 100_300
        )
        self.assertTrue(recovered_baseline.valid)
        self.assertTrue(recovered_advance.valid)

    def test_rejects_malformed_and_oversized_bodies(self) -> None:
        validator = HeartbeatValidator()
        self.assertFalse(validator.evaluate(200, b"{", 100_000).valid)
        self.assertFalse(validator.evaluate(200, b"x" * 65_537, 100_000).valid)


class HeartbeatClientTests(unittest.TestCase):
    def test_http_client_accepts_healthy_payload_and_rejects_503(self) -> None:
        call_count = 0

        def get(handler: BaseHTTPRequestHandler) -> None:
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                send_json(handler, 200, healthy_payload(99_900))
            else:
                send_json(handler, 503, {"ok": False})

        with TestHTTPServer(get_handler=get) as server:
            client = HeartbeatClient(f"{server.url}/health")
            self.assertTrue(client.fetch(100_000).valid)
            self.assertFalse(client.fetch(100_100).valid)

    def test_http_client_rejects_redirect(self) -> None:
        def get(handler: BaseHTTPRequestHandler) -> None:
            handler.send_response(302)
            handler.send_header("Location", "/other")
            handler.end_headers()

        with TestHTTPServer(get_handler=get) as server:
            result = HeartbeatClient(f"{server.url}/health").fetch(100_000)
            self.assertFalse(result.valid)

    def test_endpoint_url_rejects_credentials_and_non_http_scheme(self) -> None:
        with self.assertRaises(ConfigurationError):
            validate_endpoint_url("ftp://example.test/health", "heartbeat URL")
        with self.assertRaises(ConfigurationError):
            validate_endpoint_url(
                "https://user:secret@example.test/health", "heartbeat URL"
            )


class FailoverStateTests(unittest.TestCase):
    def test_health_never_automatically_returns_from_backup(self) -> None:
        state = FailoverState()
        for index in range(5):
            state.observe(observation(1000 + index), 2000 + index)
        self.assertEqual(state.selected_input, "backup")
        self.assertTrue(state.backup_latched)
        self.assertEqual(state.valid_healthy_samples, 5)

    def test_bad_heartbeat_immediately_latches_backup(self) -> None:
        state = FailoverState(
            selected_input="primary",
            backup_latched=False,
            reason="operator selected primary",
        )
        state.observe(HeartbeatObservation(False, "heartbeat stale"), 2000)
        self.assertEqual(state.selected_input, "backup")
        self.assertTrue(state.backup_latched)
        self.assertEqual(state.backup_latched_at_ms, 2000)
        self.assertEqual(state.valid_healthy_samples, 0)

    def test_return_requires_sample_count_and_freshness(self) -> None:
        state = FailoverState()
        state.observe(observation(1000), 2000)
        state.observe(observation(1100), 2100)
        self.assertFalse(state.can_return_primary(2200, 3, 1000)[0])
        state.observe(observation(1200), 2200)
        self.assertTrue(state.can_return_primary(2300, 3, 1000)[0])
        self.assertFalse(state.can_return_primary(3300, 3, 1000)[0])


class RelayClientTests(unittest.TestCase):
    def test_primary_uses_short_lease_and_validated_acknowledgement(self) -> None:
        received: Dict[str, Any] = {}

        def post(handler: BaseHTTPRequestHandler, body: bytes) -> None:
            command = json.loads(body)
            received.update(command)
            send_json(
                handler,
                200,
                {
                    "formatVersion": FORMAT_VERSION,
                    "kind": RELAY_ACK_KIND,
                    "requestId": command["requestId"],
                    "ok": True,
                    "selectedInput": command["selectedInput"],
                    "latched": command["latch"],
                },
            )

        with TestHTTPServer(post_handler=post) as server:
            result = RelayClient(
                f"{server.url}/selection", lease_ms=1500
            ).select("primary", "operator return", 100_000)
        self.assertTrue(result.ok)
        self.assertEqual(received["selectedInput"], "primary")
        self.assertEqual(received["leaseMs"], 1500)
        self.assertFalse(received["latch"])
        self.assertTrue(received["manualReturnRequired"])

    def test_backup_is_latched_and_has_no_primary_lease(self) -> None:
        received: Dict[str, Any] = {}

        def post(handler: BaseHTTPRequestHandler, body: bytes) -> None:
            command = json.loads(body)
            received.update(command)
            send_json(
                handler,
                200,
                {
                    "formatVersion": FORMAT_VERSION,
                    "kind": RELAY_ACK_KIND,
                    "requestId": command["requestId"],
                    "ok": True,
                    "selectedInput": "backup",
                    "latched": True,
                },
            )

        with TestHTTPServer(post_handler=post) as server:
            result = RelayClient(f"{server.url}/selection").select(
                "backup", "startup", 100_000
            )
        self.assertTrue(result.ok)
        self.assertEqual(received["leaseMs"], 0)
        self.assertTrue(received["latch"])

    def test_mismatched_acknowledgement_fails_closed(self) -> None:
        def post(handler: BaseHTTPRequestHandler, body: bytes) -> None:
            command = json.loads(body)
            send_json(
                handler,
                200,
                {
                    "formatVersion": FORMAT_VERSION,
                    "kind": RELAY_ACK_KIND,
                    "requestId": command["requestId"],
                    "ok": True,
                    "selectedInput": "backup",
                    "latched": True,
                },
            )

        with TestHTTPServer(post_handler=post) as server:
            result = RelayClient(f"{server.url}/selection").select(
                "primary", "operator return", 100_000
            )
        self.assertFalse(result.ok)

    def test_bearer_token_file_must_be_private_and_is_sent(self) -> None:
        authorization: List[Optional[str]] = []

        def post(handler: BaseHTTPRequestHandler, body: bytes) -> None:
            command = json.loads(body)
            authorization.append(handler.headers.get("Authorization"))
            send_json(
                handler,
                200,
                {
                    "formatVersion": FORMAT_VERSION,
                    "kind": RELAY_ACK_KIND,
                    "requestId": command["requestId"],
                    "ok": True,
                    "selectedInput": "backup",
                    "latched": True,
                },
            )

        with tempfile.TemporaryDirectory() as directory:
            token_path = Path(directory) / "token"
            token_path.write_text("test-token\n", encoding="utf-8")
            os.chmod(token_path, 0o600)
            with TestHTTPServer(post_handler=post) as server:
                client = RelayClient(
                    f"{server.url}/selection", bearer_token_file=token_path
                )
                self.assertTrue(client.select("backup", "startup", 100_000).ok)
                os.chmod(token_path, 0o644)
                self.assertFalse(client.select("backup", "startup", 100_100).ok)
                os.chmod(token_path, 0o600)
                symlink_path = Path(directory) / "token-link"
                symlink_path.symlink_to(token_path)
                symlink_client = RelayClient(
                    f"{server.url}/selection",
                    bearer_token_file=symlink_path,
                )
                self.assertFalse(
                    symlink_client.select("backup", "startup", 100_200).ok
                )
        self.assertEqual(authorization, ["Bearer test-token"])

    def test_unsafe_lease_lengths_are_rejected(self) -> None:
        with self.assertRaises(ConfigurationError):
            RelayClient("http://127.0.0.1/relay", lease_ms=2000)
        with self.assertRaises(ConfigurationError):
            RelayClient(
                "http://127.0.0.1/relay",
                lease_ms=500,
                timeout_seconds=0.5,
            )
        with self.assertRaises(ConfigurationError):
            validate_timing_budget(500, 500, 500, 1500)


class SupervisorTests(unittest.TestCase):
    def test_realtime_step_polls_the_heartbeat_exactly_once(self) -> None:
        heartbeat = FakeHeartbeatClient([observation(1000)])
        supervisor = FailoverSupervisor(heartbeat, FakeRelayClient())
        supervisor.start(2000)
        supervisor.step()
        self.assertEqual(len(heartbeat.calls), 1)

    def test_startup_and_restart_always_command_backup(self) -> None:
        relay = FakeRelayClient()
        first = FailoverSupervisor(FakeHeartbeatClient([]), relay)
        first.start(1000)
        first.state.mark_primary()
        first.shutdown(1500)
        restarted = FailoverSupervisor(FakeHeartbeatClient([]), relay)
        restarted.start(2000)
        self.assertEqual(
            [call["selectedInput"] for call in relay.calls],
            ["backup", "backup", "backup"],
        )
        self.assertEqual(restarted.state.selected_input, "backup")

    def test_healthy_samples_require_explicit_return_then_fault_goes_backup(self) -> None:
        heartbeat = FakeHeartbeatClient(
            [
                observation(1000),
                observation(1100),
                observation(1200),
                HeartbeatObservation(False, "heartbeat unavailable"),
            ]
        )
        relay = FakeRelayClient()
        supervisor = FailoverSupervisor(heartbeat, relay)
        supervisor.start(2000)
        supervisor.step(2100)
        supervisor.step(2200)
        supervisor.step(2300)
        self.assertEqual(supervisor.state.selected_input, "backup")
        accepted, _ = supervisor.request_primary_return(2350)
        self.assertTrue(accepted)
        self.assertEqual(supervisor.state.selected_input, "primary")
        supervisor.step(2400)
        self.assertEqual(supervisor.state.selected_input, "backup")
        self.assertTrue(supervisor.state.backup_latched)

    def test_failed_primary_ack_keeps_backup_selected(self) -> None:
        heartbeat = FakeHeartbeatClient(
            [observation(1000), observation(1100), observation(1200)]
        )
        relay = FakeRelayClient()
        supervisor = FailoverSupervisor(heartbeat, relay)
        supervisor.start(2000)
        supervisor.step(2100)
        supervisor.step(2200)
        supervisor.step(2300)
        relay.fail_primary = True
        accepted, _ = supervisor.request_primary_return(2350)
        self.assertFalse(accepted)
        self.assertEqual(supervisor.state.selected_input, "backup")
        self.assertEqual(relay.calls[-1]["selectedInput"], "backup")
        rejected, rejection = supervisor.request_primary_return(
            2450, operator_issued_at_ms=2349
        )
        self.assertFalse(rejected)
        self.assertIn("predates", rejection)

    def test_failed_primary_lease_refresh_forces_backup(self) -> None:
        heartbeat = FakeHeartbeatClient(
            [
                observation(1000),
                observation(1100),
                observation(1200),
                observation(1300),
            ]
        )
        relay = FakeRelayClient()
        supervisor = FailoverSupervisor(heartbeat, relay)
        supervisor.start(2000)
        supervisor.step(2100)
        supervisor.step(2200)
        supervisor.step(2300)
        self.assertTrue(supervisor.request_primary_return(2350)[0])
        relay.fail_primary = True
        supervisor.step(2400)
        self.assertEqual(supervisor.state.selected_input, "backup")
        self.assertEqual(relay.calls[-1]["selectedInput"], "backup")

    def test_resuming_after_lease_deadline_never_reasserts_primary(self) -> None:
        monotonic_now = [10.0]
        heartbeat = FakeHeartbeatClient(
            [
                observation(1000),
                observation(1100),
                observation(1200),
                observation(1300),
            ]
        )
        relay = FakeRelayClient()
        supervisor = FailoverSupervisor(
            heartbeat,
            relay,
            monotonic_clock=lambda: monotonic_now[0],
        )
        supervisor.start(2000)
        supervisor.step(2100)
        supervisor.step(2200)
        supervisor.step(2300)
        self.assertTrue(supervisor.request_primary_return(2350)[0])
        primary_call_count = sum(
            call["selectedInput"] == "primary" for call in relay.calls
        )

        monotonic_now[0] += 2.0
        supervisor.step(2400)

        self.assertEqual(supervisor.state.selected_input, "backup")
        self.assertTrue(supervisor.state.backup_latched)
        self.assertIn("deadline was missed", supervisor.state.reason)
        self.assertEqual(
            sum(call["selectedInput"] == "primary" for call in relay.calls),
            primary_call_count,
        )
        self.assertEqual(relay.calls[-1]["selectedInput"], "backup")

    def test_status_and_journal_are_private_and_machine_readable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            status_path = Path(directory) / "state" / "status.json"
            journal_path = Path(directory) / "state" / "events.jsonl"
            supervisor = FailoverSupervisor(
                FakeHeartbeatClient([observation(1000)]),
                FakeRelayClient(),
                AtomicStatusWriter(status_path),
                EventJournal(journal_path),
            )
            supervisor.start(2000)
            supervisor.step(2100)
            status_payload = json.loads(status_path.read_text(encoding="utf-8"))
            events = [
                json.loads(line)
                for line in journal_path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(status_payload["kind"], STATUS_KIND)
            self.assertEqual(status_payload["selectedInput"], "backup")
            self.assertEqual(stat.S_IMODE(status_path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(journal_path.stat().st_mode), 0o600)
            self.assertEqual(events[0]["event"], "startup-backup-command")


class OperatorControlTests(unittest.TestCase):
    def test_private_socket_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            socket_path = Path(directory) / "control" / "control.sock"
            server = OperatorControlServer(socket_path)
            server.open()
            self.assertEqual(stat.S_IMODE(socket_path.stat().st_mode), 0o600)
            result: Dict[str, Any] = {}
            failure: List[BaseException] = []

            def client() -> None:
                try:
                    result.update(
                        send_control_command(socket_path, "return-primary", 1.0)
                    )
                except BaseException as error:
                    failure.append(error)

            thread = threading.Thread(target=client)
            thread.start()
            deadline = time.monotonic() + 1.0
            while thread.is_alive() and time.monotonic() < deadline:
                server.serve_pending(
                    lambda _command, _issued_at_ms: (True, "accepted")
                )
                time.sleep(0.005)
            thread.join(timeout=1.0)
            server.close()
            self.assertFalse(failure)
            self.assertEqual(result["kind"], CONTROL_RESULT_KIND)
            self.assertTrue(result["accepted"])
            self.assertFalse(socket_path.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
