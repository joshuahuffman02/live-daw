import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
import uuid


SCRIPT = Path(__file__).with_name("run-recording-session-replay.py")


class RecordingSessionReplayTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.session = self.root / "session"
        self.derived = self.session / "Derived"
        self.derived.mkdir(parents=True)
        self.binary = self.root / "fake-replay"
        self.binary.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json
            from pathlib import Path
            import sys

            values = {sys.argv[i]: sys.argv[i + 1] for i in range(1, len(sys.argv) - 1, 2)}
            source = Path(values["--input"])
            failed = "unsafe" in source.name
            Path(values["--output"]).write_bytes(b"program")
            Path(values["--metrics"]).write_text(json.dumps({"safetyPassed": not failed}))
            Path(values["--decisions"]).write_text("{}\\n")
            print("fake render")
            raise SystemExit(1 if failed else 0)
        """), encoding="utf-8")
        self.binary.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def write_request(self, names, inputs=None, output_directory=None):
        for name in names:
            (self.session / name).write_bytes(b"RIFF-test")
        payload = {
            "schemaVersion": 1,
            "sessionID": str(uuid.uuid4()),
            "sessionName": "Sunday service",
            "scene": "worship",
            "roles": ["keys", "keys"],
            "stereoPairs": ["1-2"],
            "inputs": inputs or [str(self.session / name) for name in names],
            "outputDirectory": str(output_directory or self.derived),
        }
        request = self.derived / "Replay Request.json"
        request.write_text(json.dumps(payload), encoding="utf-8")
        return request

    def run_script(self, request):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(request), "--replay-binary", str(self.binary)],
            capture_output=True,
            text=True,
            check=False,
        )

    def latest_index(self):
        indexes = sorted((self.derived / "Replay Runs").glob("run-*/replay-index.json"))
        self.assertTrue(indexes)
        return json.loads(indexes[-1].read_text(encoding="utf-8"))

    def test_renders_every_segment_into_a_unique_non_destructive_run(self):
        request = self.write_request(["capture-part-0001.wav", "capture-part-0002.wav"])
        first = self.run_script(request)
        second = self.run_script(request)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        runs = list((self.derived / "Replay Runs").glob("run-*"))
        self.assertEqual(len(runs), 2)
        index = self.latest_index()
        self.assertEqual(index["status"], "passed")
        self.assertEqual(index["segmentCount"], 2)
        self.assertTrue(all(segment["output"] for segment in index["segments"]))

    def test_recovers_stale_absolute_inputs_after_session_folder_move(self):
        request = self.write_request(
            ["capture-part-0001.wav"],
            inputs=["/old/location/capture-part-0001.wav"],
            output_directory=Path("/old/location/Derived"),
        )
        completed = self.run_script(request)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.latest_index()["status"], "passed")

    def test_safety_failure_returns_one_and_keeps_the_run_index(self):
        request = self.write_request(["unsafe-part.wav"])
        completed = self.run_script(request)
        self.assertEqual(completed.returncode, 1, completed.stderr)
        index = self.latest_index()
        self.assertEqual(index["status"], "safetyFailed")
        self.assertFalse(index["segments"][0]["safetyPassed"])

    def test_rejects_an_existing_external_output_directory(self):
        external = self.root / "external"
        external.mkdir()
        request = self.write_request(["capture.wav"], output_directory=external)
        completed = self.run_script(request)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("output must remain", completed.stderr)
        self.assertFalse((self.derived / "Replay Runs").exists())


if __name__ == "__main__":
    unittest.main()
