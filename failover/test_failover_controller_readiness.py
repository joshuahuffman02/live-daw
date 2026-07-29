#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))

import audit_failover_controller as readiness  # noqa: E402


NOW_MS = 1_785_284_800_000


class FailoverControllerReadinessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="automix-failover-readiness-"
        )
        self.root = Path(self.temporary.name)
        self.config = self.root / "supervisor.json"
        self.token = self.root / "relay-token"
        self.status = self.root / "status.json"
        self.unit = self.root / "automix-failover.service"
        self.supervisor = self.root / "automix_failover_supervisor.py"
        self.audit_tool = self.root / "audit_failover_controller.py"
        self.signing_key = self.root / "readiness-signing-key"
        generated = subprocess.run(
            [
                str(readiness.SSH_KEYGEN),
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-f",
                str(self.signing_key),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.token.write_text("fixture-token\n", encoding="utf-8")
        self.token.chmod(0o600)
        self.config.write_text(
            json.dumps(
                {
                    "formatVersion": 1,
                    "kind": "automix-failover-supervisor-config",
                    "heartbeatUrl": "http://automix-primary.test:8420/health",
                    "relayUrl": "https://relay.test/v1/selection",
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
            ),
            encoding="utf-8",
        )
        self.config.chmod(0o600)
        self.status.write_text(
            json.dumps(self.valid_status()),
            encoding="utf-8",
        )
        self.status.chmod(0o600)
        self.unit.write_text("[Service]\nProtectSystem=strict\n", encoding="utf-8")
        self.unit.chmod(0o644)
        self.supervisor.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.supervisor.chmod(0o755)
        self.audit_tool.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.audit_tool.chmod(0o755)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def valid_status() -> dict[str, Any]:
        return {
            "formatVersion": 1,
            "kind": "automix-failover-supervisor-status",
            "updatedAtMs": NOW_MS - 250,
            "selectedInput": "backup",
            "backupLatched": True,
            "manualReturnRequired": True,
            "relayConfirmed": True,
            "relayRequestId": "request-backup-1",
            "primaryLeaseRemainingMs": 0,
        }

    def valid_systemd(self) -> dict[str, str]:
        return {
            "LoadState": "loaded",
            "ActiveState": "active",
            "SubState": "running",
            "UnitFileState": "enabled",
            "User": "automix-failover",
            "Group": "automix-failover",
            "Restart": "always",
            "NoNewPrivileges": "yes",
            "ProtectSystem": "strict",
            "NeedDaemonReload": "no",
            "MainPID": "421",
            "FragmentPath": str(self.unit),
        }

    def audit(self, **overrides: Any) -> dict[str, Any]:
        values: dict[str, Any] = {
            "config_path": self.config,
            "status_path": self.status,
            "unit_path": self.unit,
            "supervisor_path": self.supervisor,
            "signing_key_path": self.signing_key,
            "audit_path": self.audit_tool,
            "primary_hostname": "automix-primary.test",
            "controller_hostname": "automix-failover.test",
            "now_ms": NOW_MS,
            "systemd_reader": self.valid_systemd,
            "expected_package_uid": os.getuid(),
            "expected_package_gid": os.getgid(),
        }
        values.update(overrides)
        return readiness.audit_controller(**values)

    def test_complete_controller_is_ready_without_exposing_credentials(
        self,
    ) -> None:
        report = self.audit()
        self.assertTrue(report["ready"])
        self.assertTrue(report["notProductionAcceptance"])
        self.assertEqual(
            report["summary"], {"passed": 6, "failed": 0, "total": 6}
        )
        self.assertEqual(
            {item["id"] for item in report["checks"]},
            readiness.EXPECTED_CHECK_IDS,
        )
        self.assertEqual(report["relay"]["selectedInput"], "backup")
        self.assertEqual(
            report["software"]["supervisorSHA256"],
            readiness.hash_file(self.supervisor),
        )
        self.assertEqual(
            report["software"]["auditSHA256"],
            readiness.hash_file(self.audit_tool),
        )
        serialized = json.dumps(report)
        self.assertNotIn("fixture-token", serialized)
        self.assertNotIn(str(self.token), serialized)

    def test_same_host_stale_status_and_unhardened_service_fail_closed(
        self,
    ) -> None:
        same_host = self.audit(controller_hostname="automix-primary.test")
        self.assertFalse(same_host["ready"])
        self.assertFalse(
            next(
                item
                for item in same_host["checks"]
                if item["id"] == "controller.separate-failure-domain"
            )["passed"]
        )

        self.signing_key.chmod(0o644)
        insecure_signer = self.audit()
        self.assertFalse(insecure_signer["ready"])
        self.assertFalse(
            next(
                item
                for item in insecure_signer["checks"]
                if item["id"] == "controller.signing-key"
            )["passed"]
        )
        self.signing_key.chmod(0o600)

        status = self.valid_status()
        status["updatedAtMs"] = NOW_MS - 2_001
        self.status.write_text(json.dumps(status), encoding="utf-8")
        stale = self.audit()
        self.assertFalse(stale["ready"])
        self.assertFalse(
            next(
                item
                for item in stale["checks"]
                if item["id"] == "relay.fresh-backup-latch"
            )["passed"]
        )

        self.status.write_text(
            json.dumps(self.valid_status()), encoding="utf-8"
        )
        properties = self.valid_systemd()
        properties["NoNewPrivileges"] = "no"
        service = self.audit(systemd_reader=lambda: properties)
        self.assertFalse(service["ready"])
        self.assertFalse(
            next(
                item
                for item in service["checks"]
                if item["id"] == "controller.systemd-service"
            )["passed"]
        )

    def test_insecure_config_and_writable_package_are_rejected(self) -> None:
        config = json.loads(self.config.read_text(encoding="utf-8"))
        config["relayUrl"] = "http://relay.test/v1/selection"
        self.config.write_text(json.dumps(config), encoding="utf-8")
        rejected = self.audit()
        self.assertFalse(rejected["ready"])
        self.assertIn(
            "HTTPS",
            next(
                item
                for item in rejected["checks"]
                if item["id"] == "controller.production-config"
            )["summary"],
        )

        config["relayUrl"] = "https://relay.test/v1/selection"
        self.config.write_text(json.dumps(config), encoding="utf-8")
        self.unit.chmod(0o666)
        writable = self.audit()
        self.assertFalse(writable["ready"])
        self.assertFalse(
            next(
                item
                for item in writable["checks"]
                if item["id"] == "controller.software-unit-integrity"
            )["passed"]
        )

        self.unit.chmod(0o644)
        wrong_owner = self.audit(expected_package_uid=os.getuid() + 1)
        self.assertFalse(wrong_owner["ready"])
        self.assertFalse(
            next(
                item
                for item in wrong_owner["checks"]
                if item["id"] == "controller.software-unit-integrity"
            )["passed"]
        )

    def test_report_write_is_owner_only_atomic_and_refuses_symlinks(
        self,
    ) -> None:
        report = self.audit()
        output = self.root / "readiness.json"
        readiness.write_report(output, report, replace=False)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        with self.assertRaises(FileExistsError):
            readiness.write_report(output, report, replace=False)
        readiness.write_report(output, report, replace=True)
        linked = self.root / "linked.json"
        linked.symlink_to(output)
        with self.assertRaises(ValueError):
            readiness.write_report(linked, report, replace=True)

    def test_systemctl_reader_requires_every_named_property(self) -> None:
        properties = self.valid_systemd()
        response = "\n".join(
            f"{key}={value}" for key, value in properties.items()
        )
        with mock.patch.object(
            readiness.subprocess,
            "run",
            return_value=SimpleNamespace(returncode=0, stdout=response),
        ) as run:
            observed = readiness.read_systemd_properties()
        self.assertEqual(observed, properties)
        arguments = run.call_args.args[0]
        self.assertEqual(arguments[:4], [
            "systemctl",
            "show",
            "automix-failover.service",
            "--no-pager",
        ])
        self.assertEqual(arguments.count("--property"), len(properties))

    def test_signed_report_is_trusted_and_tampering_is_rejected(self) -> None:
        report = self.audit()
        output = self.root / "signed-readiness.json"
        signature = readiness.write_signed_report(
            output,
            report,
            self.signing_key,
            replace=False,
            expected_owner_uid=os.getuid(),
            expected_owner_gid=os.getgid(),
        )
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(signature.stat().st_mode), 0o600)
        public_key = readiness.read_signing_public_key(
            self.signing_key,
            os.getuid(),
            os.getgid(),
        )
        trusted = self.root / "trusted-signers"
        trusted.write_text(
            f"{readiness.SIGNER_IDENTITY} {public_key}\n",
            encoding="utf-8",
        )
        verified = subprocess.run(
            [
                str(readiness.SSH_KEYGEN),
                "-Y",
                "verify",
                "-f",
                str(trusted),
                "-I",
                readiness.SIGNER_IDENTITY,
                "-n",
                readiness.SIGNATURE_NAMESPACE,
                "-s",
                str(signature),
            ],
            input=output.read_bytes(),
            capture_output=True,
            check=False,
            timeout=5,
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)

        output.write_bytes(output.read_bytes() + b" ")
        rejected = subprocess.run(
            [
                str(readiness.SSH_KEYGEN),
                "-Y",
                "verify",
                "-f",
                str(trusted),
                "-I",
                readiness.SIGNER_IDENTITY,
                "-n",
                readiness.SIGNATURE_NAMESPACE,
                "-s",
                str(signature),
            ],
            input=output.read_bytes(),
            capture_output=True,
            check=False,
            timeout=5,
        )
        self.assertNotEqual(rejected.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
