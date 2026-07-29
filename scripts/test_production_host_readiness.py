#!/usr/bin/env python3

from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SCRIPT = Path(__file__).with_name("audit-production-host-readiness.py")
SPEC = importlib.util.spec_from_file_location("production_host_readiness", SCRIPT)
assert SPEC and SPEC.loader
readiness = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = readiness
SPEC.loader.exec_module(readiness)
PRODUCTION_SIGNATURE_CONTRACT = readiness.production_signature_contract

NOW = dt.datetime(2026, 7, 29, 1, 0, tzinfo=dt.timezone.utc)
INPUT_UID = "real-hd96-dante-input"
OUTPUT_UID = "blackhole-2ch-stream-output"


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


class RedirectHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(302)
            self.send_header("Location", "/real-health")
            self.end_headers()
            return
        if self.path == "/compressed":
            body = b"{}"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        body = json.dumps(
            {
                "formatVersion": 1,
                "kind": "automix-obs-encoder-health",
                "productionEligible": True,
                "healthy": True,
                "streaming": True,
                "audioActive": True,
                "timestampMs": int(NOW.timestamp() * 1_000),
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


class ProductionHostReadinessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="automix-production-host-readiness-"
        )
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.home = self.root / "home"
        self.repo.mkdir()
        self.home.mkdir()
        failover_source = (
            self.repo / "failover" / "automix_failover_supervisor.py"
        )
        failover_audit = (
            self.repo / "failover" / "audit_failover_controller.py"
        )
        failover_unit = self.repo / "failover" / "automix-failover.service"
        failover_source.parent.mkdir(parents=True)
        failover_source.write_text(
            "#!/usr/bin/env python3\n# fixture supervisor\n",
            encoding="utf-8",
        )
        failover_audit.write_text(
            "#!/usr/bin/env python3\n# fixture audit\n",
            encoding="utf-8",
        )
        failover_unit.write_text(
            "[Service]\nProtectSystem=strict\n",
            encoding="utf-8",
        )
        self.failover_readiness = self.root / "failover-readiness.json"
        failover_checks = [
            {
                "id": check_id,
                "passed": True,
                "summary": "fixture passed",
                "remediation": "none",
            }
            for check_id in sorted(readiness.FAILOVER_READINESS_CHECK_IDS)
        ]
        write_json(
            self.failover_readiness,
            {
                "formatVersion": 1,
                "kind": "automix-failover-controller-readiness",
                "generatedAtMs": int(NOW.timestamp() * 1_000),
                "expiresAtMs": int(NOW.timestamp() * 1_000) + 900_000,
                "ready": True,
                "notProductionAcceptance": True,
                "primaryHostname": readiness.local_hostname(),
                "controllerHostname": "failover-controller.test",
                "serviceName": "automix-failover.service",
                "config": {
                    "sha256": "c" * 64,
                    "productionContract": True,
                    "heartbeatHost": "automix-primary.test",
                    "relayHost": "relay.test",
                },
                "software": {
                    "supervisorSHA256": readiness.hash_file(
                        failover_source
                    ),
                    "auditSHA256": readiness.hash_file(failover_audit),
                    "unitSHA256": readiness.hash_file(failover_unit),
                },
                "service": {
                    "loadState": "loaded",
                    "activeState": "active",
                    "subState": "running",
                    "unitFileState": "enabled",
                    "user": "automix-failover",
                    "group": "automix-failover",
                    "restart": "always",
                    "noNewPrivileges": "yes",
                    "protectSystem": "strict",
                    "needDaemonReload": "no",
                    "mainPID": "421",
                    "fragmentPath": (
                        "/etc/systemd/system/automix-failover.service"
                    ),
                },
                "relay": {
                    "selectedInput": "backup",
                    "backupLatched": True,
                    "manualReturnRequired": True,
                    "relayConfirmed": True,
                    "relayRequestId": "fixture-backup-ack",
                    "statusUpdatedAtMs": int(NOW.timestamp() * 1_000) - 100,
                    "primaryLeaseRemainingMs": 0,
                },
                "summary": {
                    "passed": len(readiness.FAILOVER_READINESS_CHECK_IDS),
                    "failed": 0,
                    "total": len(readiness.FAILOVER_READINESS_CHECK_IDS),
                },
                "checks": failover_checks,
            },
        )
        self.failover_readiness.chmod(0o600)
        signature_patcher = mock.patch.object(
            readiness,
            "production_signature_contract",
            return_value=(
                True,
                "Developer ID, Hardened Runtime, production entitlements, and team identity verified",
            ),
        )
        signature_patcher.start()
        self.addCleanup(signature_patcher.stop)
        self.app = self.root / "AutoMix Native.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        binary = self.app / "Contents" / "MacOS" / "AutoMix Native"
        binary.write_bytes(b"app")
        binary.chmod(0o700)
        info_path = self.app / "Contents" / "Info.plist"
        info_path.write_bytes(
            plistlib.dumps(
                {
                    "CFBundleShortVersionString": "1.0.0",
                    "CFBundleVersion": "1",
                    "CFBundleIdentifier": "com.livedaw.automixnative",
                }
            )
        )
        provenance_path = (
            self.app
            / "Contents"
            / "Resources"
            / "AutoMixReleaseProvenance.plist"
        )
        provenance_path.parent.mkdir(parents=True)
        provenance_path.write_bytes(
            plistlib.dumps(
                {
                    "formatVersion": 1,
                    "kind": "automix-native-signed-provenance",
                    "sourceCommit": "a" * 40,
                    "builtAtUTC": "2026-07-29T00:58:00Z",
                    "version": "1.0.0",
                    "build": "1",
                    "bundleIdentifier": "com.livedaw.automixnative",
                }
            )
        )
        self.build_metadata = self.root / "build-metadata.json"
        write_json(
            self.build_metadata,
            {
                "formatVersion": 1,
                "kind": "automix-native-release-build",
                "version": "1.0.0",
                "build": "1",
                "commit": "a" * 40,
                "builtAtUTC": "2026-07-29T00:58:00Z",
                "bundleIdentifier": "com.livedaw.automixnative",
                "signingIdentity": "Developer ID Application: AutoMix Test (TEAMID)",
                "hardenedRuntime": True,
                "notarized": True,
                "audioInputEntitlement": True,
                "appBinarySHA256": readiness.hash_file(binary),
                "signedProvenanceResource": (
                    "Contents/Resources/AutoMixReleaseProvenance.plist"
                ),
                "signedProvenanceSHA256": readiness.hash_file(provenance_path),
            },
        )
        self.obs_app = self.root / "OBS.app"
        (self.obs_app / "Contents" / "PlugIns" / "obs-websocket.plugin").mkdir(
            parents=True
        )
        self.recording_root = self.root / "recordings"
        self.recording_root.mkdir()
        self.inventory = self.root / "inventory.json"
        self.preflight = self.root / "preflight.json"
        self.profile = self.root / "VenueProfile.json"
        write_json(
            self.inventory,
            {
                "generatedAt": "2026-07-29T00:59:00Z",
                "expectedInputChannels": 64,
                "productionReadyInputUIDs": [INPUT_UID],
                "productionReadyOutputUIDs": [OUTPUT_UID],
                "simulatedDeviceUIDs": [],
                "selectedInputUID": INPUT_UID,
                "selectedOutputUID": OUTPUT_UID,
            },
        )
        write_json(
            self.preflight,
            {
                "generatedAt": "2026-07-29T00:59:00Z",
                "validationSource": "core-audio-device",
                "expectedInputChannels": 64,
                "inputDevice": {"uid": INPUT_UID},
                "outputDevice": {"uid": OUTPUT_UID},
                "report": {"isReady": True, "summary": "HD96 route ready"},
            },
        )
        write_json(
            self.profile,
            {
                "inputDeviceUID": INPUT_UID,
                "outputDeviceUID": OUTPUT_UID,
                "expectedInputChannels": 64,
                "expectedSampleRate": 96000,
                "automaticContinuousRecordingEnabled": True,
                "plannedRecordingDurationHours": 3,
                "recordingMinimumReserveGB": 20,
                "shadowMode": True,
                "encoderHealthURL": "http://127.0.0.1:8421/health",
                "egressHealthURL": "https://observer.example.test/health",
            },
        )
        launch_agent = (
            self.home
            / "Library"
            / "LaunchAgents"
            / "com.livedaw.automixnative.plist"
        )
        launch_agent.parent.mkdir(parents=True)
        launch_agent.write_bytes(
            plistlib.dumps(
                {
                    "Label": "com.livedaw.automixnative",
                    "RunAtLoad": True,
                    "ProgramArguments": [str(binary)],
                }
            )
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def arguments(self, **overrides: object) -> SimpleNamespace:
        values: dict[str, object] = {
            "phase": "sermon",
            "repo": self.repo,
            "home": self.home,
            "app": self.app,
            "build_metadata": self.build_metadata,
            "obs_app": self.obs_app,
            "inventory": self.inventory,
            "preflight": self.preflight,
            "profile": self.profile,
            "failover_readiness": self.failover_readiness,
            "recording_root": self.recording_root,
            "expected_inputs": 64,
            "sample_rate": 96_000,
            "duration_seconds": 7_200,
            "reserve_gib": 20.0,
            "max_inventory_age_hours": 24.0,
            "network_timeout": 0.2,
            "skip_network_probes": False,
            "output": self.root / "report.json",
            "replace": False,
        }
        values.update(overrides)
        return SimpleNamespace(**values)

    @staticmethod
    def encoder_payload() -> dict:
        return {
            "formatVersion": 1,
            "kind": "automix-obs-encoder-health",
            "productionEligible": True,
            "healthy": True,
            "streaming": True,
            "audioActive": True,
            "timestampMs": int(NOW.timestamp() * 1_000),
            "authenticated": True,
            "encoderProgressing": True,
            "encoderIntervalClean": True,
            "audioInput": "AutoMix Program",
            "obsStudioVersion": "32.2.1",
        }

    @staticmethod
    def egress_payload() -> dict:
        return {
            "formatVersion": 1,
            "kind": "automix-hls-egress-health",
            "productionEligible": True,
            "healthy": True,
            "streaming": True,
            "audioActive": True,
            "timestampMs": int(NOW.timestamp() * 1_000),
            "observerSite": "offsite-cellular",
            "playbackHost": "cdn.example.test",
            "mediaSequence": 1024,
            "decodedAudioSamples": 2048,
        }

    def test_complete_host_fixture_is_ready_for_hardware_proof_run(self) -> None:
        free = SimpleNamespace(f_bavail=300, f_frsize=1024**3)
        completed = SimpleNamespace(returncode=0, stdout="")
        with (
            mock.patch.object(readiness, "run_quiet", return_value=True),
            mock.patch.object(readiness, "git_commit", return_value="a" * 40),
            mock.patch.object(readiness.subprocess, "run", return_value=completed),
            mock.patch.object(readiness.os, "statvfs", return_value=free),
            mock.patch.object(
                readiness,
                "fetch_json",
                side_effect=[self.encoder_payload(), self.egress_payload()],
            ),
        ):
            report = readiness.Auditor(self.arguments(), now=NOW).run()
        self.assertTrue(report["readyForHardwareProofRun"])
        self.assertTrue(report["notProductionAcceptance"])
        self.assertEqual(report["formatVersion"], 3)
        self.assertEqual(report["summary"], {"passed": 12, "failed": 0, "total": 12})
        self.assertEqual(
            report["inputs"]["failoverReadinessSHA256"],
            readiness.hash_file(self.failover_readiness),
        )
        self.assertTrue(all(item["passed"] for item in report["checks"]))

    def test_missing_provisioning_reports_every_blocker_without_secrets(self) -> None:
        completed = SimpleNamespace(returncode=0, stdout="")
        args = self.arguments(
            app=None,
            build_metadata=None,
            inventory=None,
            preflight=None,
            profile=None,
            failover_readiness=None,
            recording_root=None,
            obs_app=self.root / "Missing OBS.app",
            skip_network_probes=True,
        )
        with (
            mock.patch.object(readiness, "run_quiet", return_value=False),
            mock.patch.object(readiness.subprocess, "run", return_value=completed),
        ):
            report = readiness.Auditor(args, now=NOW).run()
        self.assertFalse(report["readyForHardwareProofRun"])
        ids = {item["id"] for item in report["checks"] if not item["passed"]}
        self.assertIn("app.signed-notarized-release", ids)
        self.assertIn("audio.production-route-inventory", ids)
        self.assertIn("storage.proof-window-capacity", ids)
        self.assertIn("failover.independent-controller", ids)
        self.assertIn("encoder.exact-program-observer", ids)
        serialized = json.dumps(report)
        self.assertNotIn("password", serialized.lower())
        self.assertNotIn("secret", serialized.lower())

    def test_failover_readiness_requires_separate_fresh_exact_controller(
        self,
    ) -> None:
        fixture = json.loads(
            self.failover_readiness.read_text(encoding="utf-8")
        )
        invalid_cases = (
            (
                {"primaryHostname": "different-primary.test"},
                "mismatched",
            ),
            (
                {
                    "generatedAtMs": int(NOW.timestamp() * 1_000)
                    - 900_001
                },
                "expired",
            ),
            (
                {
                    "software": {
                        **fixture["software"],
                        "supervisorSHA256": "f" * 64,
                    }
                },
                "mismatched",
            ),
            (
                {
                    "relay": {
                        **fixture["relay"],
                        "relayConfirmed": False,
                    }
                },
                "unsafe",
            ),
            (
                {
                    "service": {
                        **fixture["service"],
                        "needDaemonReload": "yes",
                    }
                },
                "unsafe",
            ),
        )
        completed = SimpleNamespace(returncode=0, stdout="")
        for changes, expected in invalid_cases:
            with self.subTest(changes=changes):
                changed = json.loads(json.dumps(fixture))
                changed.update(changes)
                write_json(self.failover_readiness, changed)
                self.failover_readiness.chmod(0o600)
                with (
                    mock.patch.object(
                        readiness, "run_quiet", return_value=True
                    ),
                    mock.patch.object(
                        readiness, "git_commit", return_value="a" * 40
                    ),
                    mock.patch.object(
                        readiness.subprocess,
                        "run",
                        return_value=completed,
                    ),
                    mock.patch.object(
                        readiness.os,
                        "statvfs",
                        return_value=SimpleNamespace(
                            f_bavail=300, f_frsize=1024**3
                        ),
                    ),
                    mock.patch.object(
                        readiness,
                        "fetch_json",
                        side_effect=[
                            self.encoder_payload(),
                            self.egress_payload(),
                        ],
                    ),
                ):
                    report = readiness.Auditor(
                        self.arguments(), now=NOW
                    ).run()
                check = next(
                    item
                    for item in report["checks"]
                    if item["id"] == "failover.independent-controller"
                )
                self.assertFalse(check["passed"])
                self.assertIn(expected, check["summary"])
        write_json(self.failover_readiness, fixture)
        self.failover_readiness.chmod(0o600)

    def test_release_metadata_cannot_be_mixed_with_a_different_signed_app(self) -> None:
        metadata = json.loads(self.build_metadata.read_text(encoding="utf-8"))
        metadata["appBinarySHA256"] = "f" * 64
        write_json(self.build_metadata, metadata)
        completed = SimpleNamespace(returncode=0, stdout="")
        with (
            mock.patch.object(readiness, "run_quiet", return_value=True),
            mock.patch.object(readiness, "git_commit", return_value="a" * 40),
            mock.patch.object(readiness.subprocess, "run", return_value=completed),
            mock.patch.object(
                readiness.os,
                "statvfs",
                return_value=SimpleNamespace(f_bavail=300, f_frsize=1024**3),
            ),
            mock.patch.object(
                readiness,
                "fetch_json",
                side_effect=[self.encoder_payload(), self.egress_payload()],
            ),
        ):
            report = readiness.Auditor(self.arguments(), now=NOW).run()
        app_check = next(
            item
            for item in report["checks"]
            if item["id"] == "app.signed-notarized-release"
        )
        self.assertFalse(app_check["passed"])
        self.assertIn("does not match", app_check["summary"])
        self.assertFalse(report["readyForHardwareProofRun"])

    def test_signed_provenance_must_match_the_published_source_commit(self) -> None:
        provenance_path = (
            self.app
            / "Contents"
            / "Resources"
            / "AutoMixReleaseProvenance.plist"
        )
        provenance = plistlib.loads(provenance_path.read_bytes())
        provenance["sourceCommit"] = "b" * 40
        provenance_path.write_bytes(plistlib.dumps(provenance))
        metadata = json.loads(self.build_metadata.read_text(encoding="utf-8"))
        metadata["commit"] = "b" * 40
        metadata["signedProvenanceSHA256"] = readiness.hash_file(provenance_path)
        write_json(self.build_metadata, metadata)
        completed = SimpleNamespace(returncode=0, stdout="")
        with (
            mock.patch.object(readiness, "run_quiet", return_value=True),
            mock.patch.object(readiness, "git_commit", return_value="a" * 40),
            mock.patch.object(readiness.subprocess, "run", return_value=completed),
            mock.patch.object(
                readiness.os,
                "statvfs",
                return_value=SimpleNamespace(f_bavail=300, f_frsize=1024**3),
            ),
            mock.patch.object(
                readiness,
                "fetch_json",
                side_effect=[self.encoder_payload(), self.egress_payload()],
            ),
        ):
            report = readiness.Auditor(self.arguments(), now=NOW).run()
        app_check = next(
            item
            for item in report["checks"]
            if item["id"] == "app.signed-notarized-release"
        )
        self.assertFalse(app_check["passed"])
        self.assertIn("source commit", app_check["summary"])

    def test_signature_contract_requires_runtime_and_production_entitlements(self) -> None:
        good_details = SimpleNamespace(
            returncode=0,
            stderr=(
                b"flags=0x10000(runtime)\n"
                b"Authority=Developer ID Application: AutoMix Test (TEAMID)\n"
                b"TeamIdentifier=TEAMID\n"
            ),
        )
        good_entitlements = SimpleNamespace(
            returncode=0,
            stdout=plistlib.dumps(
                {"com.apple.security.device.audio-input": True}
            ),
        )
        with mock.patch.object(
            readiness.subprocess,
            "run",
            side_effect=[good_details, good_entitlements],
        ):
            passed, _ = PRODUCTION_SIGNATURE_CONTRACT(self.app)
        self.assertTrue(passed)

        debug_entitlements = SimpleNamespace(
            returncode=0,
            stdout=plistlib.dumps(
                {
                    "com.apple.security.device.audio-input": True,
                    "com.apple.security.get-task-allow": True,
                }
            ),
        )
        with mock.patch.object(
            readiness.subprocess,
            "run",
            side_effect=[good_details, debug_entitlements],
        ):
            passed, summary = PRODUCTION_SIGNATURE_CONTRACT(self.app)
        self.assertFalse(passed)
        self.assertIn("Hardened Runtime", summary)

    def test_inventory_cannot_relabel_a_simulated_selected_route(self) -> None:
        inventory = json.loads(self.inventory.read_text(encoding="utf-8"))
        inventory["simulatedDeviceUIDs"] = [INPUT_UID, OUTPUT_UID]
        write_json(self.inventory, inventory)
        completed = SimpleNamespace(returncode=0, stdout="")
        with (
            mock.patch.object(readiness, "run_quiet", return_value=True),
            mock.patch.object(readiness, "git_commit", return_value="a" * 40),
            mock.patch.object(readiness.subprocess, "run", return_value=completed),
            mock.patch.object(
                readiness.os,
                "statvfs",
                return_value=SimpleNamespace(f_bavail=300, f_frsize=1024**3),
            ),
            mock.patch.object(
                readiness,
                "fetch_json",
                side_effect=[self.encoder_payload(), self.egress_payload()],
            ),
        ):
            report = readiness.Auditor(self.arguments(), now=NOW).run()
        check = next(
            item
            for item in report["checks"]
            if item["id"] == "audio.production-route-inventory"
        )
        self.assertFalse(check["passed"])
        self.assertFalse(report["readyForHardwareProofRun"])

    def test_token_bearing_health_urls_are_rejected_and_redacted(self) -> None:
        profile = json.loads(self.profile.read_text(encoding="utf-8"))
        profile["encoderHealthURL"] = "http://operator:hunter2@127.0.0.1:8421/health"
        profile["egressHealthURL"] = (
            "https://observer.example.test/health?token=super-secret-value"
        )
        write_json(self.profile, profile)
        completed = SimpleNamespace(returncode=0, stdout="")
        with (
            mock.patch.object(readiness, "run_quiet", return_value=True),
            mock.patch.object(readiness, "git_commit", return_value="a" * 40),
            mock.patch.object(readiness.subprocess, "run", return_value=completed),
            mock.patch.object(
                readiness.os,
                "statvfs",
                return_value=SimpleNamespace(f_bavail=300, f_frsize=1024**3),
            ),
        ):
            report = readiness.Auditor(self.arguments(), now=NOW).run()
        serialized = json.dumps(report)
        self.assertNotIn("hunter2", serialized)
        self.assertNotIn("super-secret-value", serialized)
        self.assertFalse(
            next(
                item
                for item in report["checks"]
                if item["id"] == "encoder.exact-program-observer"
            )["passed"]
        )
        self.assertFalse(
            next(
                item
                for item in report["checks"]
                if item["id"] == "egress.remote-playback-observer"
            )["passed"]
        )

    def test_fresh_ready_report_rechecks_bindings_and_live_host_state(self) -> None:
        free = SimpleNamespace(f_bavail=300, f_frsize=1024**3)
        completed = SimpleNamespace(returncode=0, stdout="")
        output = self.root / "bound-report.json"
        with (
            mock.patch.object(readiness, "run_quiet", return_value=True),
            mock.patch.object(readiness, "git_commit", return_value="a" * 40),
            mock.patch.object(readiness.subprocess, "run", return_value=completed),
            mock.patch.object(readiness.os, "statvfs", return_value=free),
            mock.patch.object(
                readiness,
                "fetch_json",
                side_effect=[
                    self.encoder_payload(),
                    self.egress_payload(),
                    self.encoder_payload(),
                    self.egress_payload(),
                ],
            ),
        ):
            report = readiness.Auditor(self.arguments(), now=NOW).run()
            readiness.write_report(output, report, replace=False)
            verified = readiness.verify_report(output, home=self.home, now=NOW)
        self.assertTrue(verified["readyForHardwareProofRun"])

        profile = json.loads(self.profile.read_text(encoding="utf-8"))
        profile["shadowMode"] = False
        write_json(self.profile, profile)
        with (
            mock.patch.object(readiness, "git_commit", return_value="a" * 40),
            self.assertRaisesRegex(ValueError, "bound readiness input changed"),
        ):
            readiness.verify_report(output, home=self.home, now=NOW)

        profile["shadowMode"] = True
        write_json(self.profile, profile)
        failover = json.loads(
            self.failover_readiness.read_text(encoding="utf-8")
        )
        failover["relay"]["relayConfirmed"] = False
        write_json(self.failover_readiness, failover)
        with (
            mock.patch.object(readiness, "git_commit", return_value="a" * 40),
            self.assertRaisesRegex(ValueError, "bound readiness input changed"),
        ):
            readiness.verify_report(output, home=self.home, now=NOW)

    def test_health_probe_refuses_redirects(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/health"
            with self.assertRaises(Exception):
                readiness.fetch_json(url, 1)
            compressed = f"http://127.0.0.1:{server.server_port}/compressed"
            with self.assertRaisesRegex(ValueError, "compressed health responses"):
                readiness.fetch_json(compressed, 1)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_health_url_rejects_credentials_controls_and_mapped_loopback(self) -> None:
        rejected = (
            ("http://operator:value@127.0.0.1:8421/health", "encoder"),
            ("http://127.0.0.1:8421/health?token=value", "encoder"),
            ("http://127.0.0.1:8421/health\n", "encoder"),
            ("http://[::ffff:127.0.0.1]:8422/health", "egress"),
        )
        for url, role in rejected:
            with self.subTest(url=url, role=role):
                self.assertFalse(readiness.exact_health_url(url, role)[0])
        self.assertTrue(
            readiness.exact_health_url(
                "https://observer.example.test/health", "egress"
            )[0]
        )

    def test_atomic_report_refuses_overwrite_and_symlink(self) -> None:
        report = {
            "formatVersion": 1,
            "kind": "automix-production-host-readiness",
        }
        output = self.root / "output.json"
        readiness.write_report(output, report, replace=False)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            readiness.write_report(output, report, replace=False)
        readiness.write_report(output, report, replace=True)
        symlink = self.root / "symlink.json"
        symlink.symlink_to(output)
        with self.assertRaises(ValueError):
            readiness.write_report(symlink, report, replace=True)

    def test_production_staged_runner_cannot_skip_readiness_gate(self) -> None:
        profile = self.root / "runner-profile.json"
        write_json(profile, {})
        evidence = self.root / "runner-evidence"
        script = SCRIPT.with_name("run-staged-hardware-proof.sh")
        environment = dict(os.environ)
        environment.pop("HOST_READINESS_REPORT", None)
        environment.pop("REHEARSAL_ONLY", None)
        result = subprocess.run(
            [
                str(script),
                "sermon",
                str(self.app),
                INPUT_UID,
                OUTPUT_UID,
                str(profile),
                str(evidence),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Production proof requires HOST_READINESS_REPORT", result.stderr)
        self.assertFalse(evidence.exists())


if __name__ == "__main__":
    unittest.main()
