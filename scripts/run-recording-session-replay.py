#!/usr/bin/env python3
"""Render every native recording-session segment with automix_replay.

The native app writes a versioned ``Derived/Replay Request.json``. This runner
validates that request, keeps all output inside the session, gives every run a
new directory, and records partial failures without modifying source audio.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid
from typing import Any


ALLOWED_SCENES = {"preService", "worship", "sermon", "prayer", "postService"}
PAIR_PATTERN = re.compile(r"^[1-9][0-9]*-[1-9][0-9]*$")


class RequestError(ValueError):
    pass


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _required_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise RequestError(f"Replay request field '{key}' must be a non-empty string.")
    return value.strip()


def _resolve_input(raw_path: str, session_root: Path) -> Path:
    declared = Path(raw_path).expanduser()
    if not declared.is_absolute():
        declared = session_root / declared
    try:
        resolved = declared.resolve(strict=True)
    except FileNotFoundError:
        # Absolute paths in an app-generated request become stale if the operator
        # moves the complete session folder. Recover only the same basename from
        # the current session root; never search outside it.
        relocated = session_root / declared.name
        try:
            resolved = relocated.resolve(strict=True)
        except FileNotFoundError as error:
            raise RequestError(f"Recorded segment is missing: {declared.name}") from error
    if not _inside(resolved, session_root) or not resolved.is_file() or resolved.is_symlink():
        raise RequestError(f"Recorded segment must be a regular file inside the session: {resolved}")
    if resolved.suffix.lower() not in {".wav", ".wave"}:
        raise RequestError(f"Replay only accepts WAV capture segments: {resolved.name}")
    return resolved


def load_request(request_path: Path) -> dict[str, Any]:
    try:
        canonical_request = request_path.expanduser().resolve(strict=True)
    except FileNotFoundError as error:
        raise RequestError(f"Replay request does not exist: {request_path}") from error
    if not canonical_request.is_file() or canonical_request.is_symlink():
        raise RequestError("Replay request must be a regular JSON file.")
    try:
        payload = json.loads(canonical_request.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RequestError(f"Replay request is unreadable: {error}") from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise RequestError("Replay request schemaVersion must be 1.")

    session_id = _required_string(payload, "sessionID")
    try:
        uuid.UUID(session_id)
    except ValueError as error:
        raise RequestError("Replay request sessionID must be a UUID.") from error
    _required_string(payload, "sessionName")
    scene = _required_string(payload, "scene")
    if scene not in ALLOWED_SCENES:
        raise RequestError(f"Unsupported replay scene: {scene}")

    roles = payload.get("roles")
    if not isinstance(roles, list) or not 1 <= len(roles) <= 64 or not all(
        isinstance(role, str) and role.strip() for role in roles
    ):
        raise RequestError("Replay request roles must contain 1–64 non-empty role names.")
    stereo_pairs = payload.get("stereoPairs", [])
    if not isinstance(stereo_pairs, list) or not all(
        isinstance(pair, str) and PAIR_PATTERN.fullmatch(pair) for pair in stereo_pairs
    ):
        raise RequestError("Replay request stereoPairs must use values such as 11-12.")

    derived_root = canonical_request.parent
    session_root = derived_root.parent.resolve(strict=True)
    declared_output = payload.get("outputDirectory")
    if not isinstance(declared_output, str) or not declared_output.strip():
        raise RequestError("Replay request outputDirectory must be a non-empty string.")
    output_path = Path(declared_output).expanduser()
    if not output_path.is_absolute():
        output_path = session_root / output_path
    declared_resolved = output_path.resolve(strict=False)
    if declared_resolved != derived_root:
        # Permit a stale app-generated absolute path after the whole session was
        # moved, but never redirect output into an existing external directory.
        if output_path.exists() or output_path.name != derived_root.name:
            raise RequestError("Replay output must remain in this session's Derived directory.")

    raw_inputs = payload.get("inputs")
    if not isinstance(raw_inputs, list) or not raw_inputs or not all(isinstance(value, str) for value in raw_inputs):
        raise RequestError("Replay request inputs must contain at least one WAV path.")
    inputs = [_resolve_input(value, session_root) for value in raw_inputs]
    if len(set(inputs)) != len(inputs):
        raise RequestError("Replay request contains the same segment more than once.")

    return {
        "requestPath": canonical_request,
        "sessionRoot": session_root,
        "derivedRoot": derived_root,
        "sessionID": session_id,
        "sessionName": payload["sessionName"].strip(),
        "scene": scene,
        "roles": [role.strip() for role in roles],
        "stereoPairs": stereo_pairs,
        "inputs": inputs,
    }


def find_replay_binary(explicit: str | None, repository_root: Path) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    from_path = shutil.which("automix_replay")
    if from_path:
        candidates.append(Path(from_path))
    candidates.extend([
        repository_root / "appliance" / "build" / "automix_replay",
        repository_root / "build" / "automix_replay",
    ])
    for candidate in candidates:
        try:
            resolved = candidate.resolve(strict=True)
        except FileNotFoundError:
            continue
        if resolved.is_file() and os.access(resolved, os.X_OK):
            return resolved
    raise RequestError("automix_replay was not found. Build it or pass --replay-binary.")


def _write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}-{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def run_request(request: dict[str, Any], replay_binary: Path, block_size: int) -> tuple[int, Path]:
    runs_root = request["derivedRoot"] / "Replay Runs"
    runs_root.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    run_directory = runs_root / f"run-{stamp}-{uuid.uuid4().hex[:8]}"
    run_directory.mkdir()

    results: list[dict[str, Any]] = []
    has_processing_failure = False
    has_safety_failure = False
    roles = ",".join(request["roles"])
    stereo_pairs = ",".join(request["stereoPairs"])

    for index, input_path in enumerate(request["inputs"], start=1):
        stem = f"part-{index:04d}"
        output = run_directory / f"{stem}-program.wav"
        metrics = run_directory / f"{stem}-metrics.json"
        decisions = run_directory / f"{stem}-decisions.jsonl"
        command = [
            str(replay_binary),
            "--input", str(input_path),
            "--roles", roles,
            "--scene", request["scene"],
            "--block-size", str(block_size),
            "--output", str(output),
            "--metrics", str(metrics),
            "--decisions", str(decisions),
        ]
        if stereo_pairs:
            command.extend(["--stereo-pairs", stereo_pairs])
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
        metric_payload: dict[str, Any] | None = None
        if metrics.is_file():
            try:
                loaded = json.loads(metrics.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    metric_payload = loaded
            except (OSError, json.JSONDecodeError):
                metric_payload = None
        if completed.returncode == 1:
            has_safety_failure = True
        elif completed.returncode != 0:
            has_processing_failure = True
        if metric_payload is None:
            has_processing_failure = True
        results.append({
            "index": index,
            "input": str(input_path),
            "output": output.name if output.exists() else None,
            "metrics": metrics.name if metrics.exists() else None,
            "decisions": decisions.name if decisions.exists() else None,
            "exitCode": completed.returncode,
            "safetyPassed": metric_payload.get("safetyPassed") if metric_payload else None,
            "stdout": completed.stdout.strip(),
            "stderr": completed.stderr.strip(),
        })

    status = "failed" if has_processing_failure else ("safetyFailed" if has_safety_failure else "passed")
    index_payload = {
        "schemaVersion": 1,
        "sessionID": request["sessionID"],
        "sessionName": request["sessionName"],
        "request": str(request["requestPath"]),
        "replayBinary": str(replay_binary),
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "scene": request["scene"],
        "roles": request["roles"],
        "stereoPairs": request["stereoPairs"],
        "blockSize": block_size,
        "segmentCount": len(results),
        "status": status,
        "segments": results,
        "continuityNote": (
            "Each capture segment is rendered independently. Use the per-part outputs for listening and triage; "
            "do not treat cross-boundary control state as a continuous full-service evaluation."
        ),
    }
    index_path = run_directory / "replay-index.json"
    _write_json_atomic(index_path, index_payload)
    if has_processing_failure:
        return 2, index_path
    if has_safety_failure:
        return 1, index_path
    return 0, index_path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render an AutoMix native recording-session replay request.")
    parser.add_argument("request", type=Path, help="Path to Derived/Replay Request.json")
    parser.add_argument("--replay-binary", help="Path to the automix_replay executable")
    parser.add_argument("--block-size", type=int, default=256, help="Replay block size (16–4096, default 256)")
    args = parser.parse_args(argv)
    if not 16 <= args.block_size <= 4096:
        parser.error("--block-size must be between 16 and 4096")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    repository_root = Path(__file__).resolve().parent.parent
    try:
        request = load_request(args.request)
        replay_binary = find_replay_binary(args.replay_binary, repository_root)
        status, index_path = run_request(request, replay_binary, args.block_size)
        print(f"Replay {json.loads(index_path.read_text(encoding='utf-8'))['status']}: {index_path}")
        return status
    except RequestError as error:
        print(f"recording-session-replay: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("recording-session-replay: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
