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
        self.app = self.root / "AutoMix Native.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        binary = self.app / "Contents" / "MacOS" / "AutoMix Native"
        binary.write_bytes(b"app")
        binary.chmod(0o700)
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
            "obs_app": self.obs_app,
            "inventory": self.inventory,
            "preflight": self.preflight,
            "profile": self.profile,
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
        self.assertEqual(report["summary"], {"passed": 11, "failed": 0, "total": 11})
        self.assertTrue(all(item["passed"] for item in report["checks"]))

    def test_missing_provisioning_reports_every_blocker_without_secrets(self) -> None:
        completed = SimpleNamespace(returncode=0, stdout="")
        args = self.arguments(
            app=None,
            inventory=None,
            preflight=None,
            profile=None,
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
        self.assertIn("encoder.exact-program-observer", ids)
        serialized = json.dumps(report)
        self.assertNotIn("password", serialized.lower())
        self.assertNotIn("secret", serialized.lower())

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
