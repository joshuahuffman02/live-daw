#!/usr/bin/env python3

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import stat
import struct
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))

from obs_health_bridge import (  # noqa: E402
    AudioInputSelector,
    ConfigurationError,
    EncoderHealthState,
    FORMAT_VERSION,
    HEALTH_KIND,
    HealthHTTPServer,
    OBS_EVENT_SUBSCRIPTIONS,
    OBS_INPUT_EVENTS,
    OBS_INPUT_VOLUME_METERS,
    OBS_OUTPUT_EVENTS,
    OBSMonitor,
    OBSProtocolSession,
    WEBSOCKET_GUID,
    WebSocketProtocolError,
    make_health_handler,
    obs_authentication_string,
    read_private_secret,
    validate_loopback_host,
)


def wait_until(predicate: Any, timeout_seconds: float = 3.0) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return bool(predicate())


def encode_server_frame(
    payload: bytes,
    opcode: int = 0x1,
    finished: bool = True,
    masked: bool = False,
) -> bytes:
    first = (0x80 if finished else 0) | opcode
    length = len(payload)
    mask_bit = 0x80 if masked else 0
    if length < 126:
        header = bytes((first, mask_bit | length))
    elif length <= 0xFFFF:
        header = bytes((first, mask_bit | 126)) + struct.pack("!H", length)
    else:
        header = bytes((first, mask_bit | 127)) + struct.pack("!Q", length)
    if not masked:
        return header + payload
    mask = b"\x11\x22\x33\x44"
    encoded = bytes(value ^ mask[index & 3] for index, value in enumerate(payload))
    return header + mask + encoded


def read_exact(connection: socket.socket, size: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        chunk = connection.recv(size - len(result))
        if not chunk:
            raise EOFError("connection closed")
        result.extend(chunk)
    return bytes(result)


def read_client_frame(connection: socket.socket) -> Tuple[int, bytes]:
    first, second = read_exact(connection, 2)
    if not first & 0x80:
        raise AssertionError("test client frame must not be fragmented")
    opcode = first & 0x0F
    if not second & 0x80:
        raise AssertionError("WebSocket client frame must be masked")
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(connection, 8))[0]
    mask = read_exact(connection, 4)
    payload = read_exact(connection, length)
    decoded = bytes(value ^ mask[index & 3] for index, value in enumerate(payload))
    return opcode, decoded


def read_http_headers(connection: socket.socket) -> str:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(4096)
        if not chunk:
            raise EOFError("connection closed during HTTP request")
        data.extend(chunk)
        if len(data) > 16 * 1024:
            raise AssertionError("test HTTP request is too large")
    return data.decode("iso-8859-1")


class FakeOBSServer:
    def __init__(
        self,
        *,
        authentication_required: bool = True,
        valid_upgrade_accept: bool = True,
        negotiated_subprotocol: str = "obswebsocket.json",
        mask_server_frames: bool = False,
        request_succeeds: bool = True,
        streaming: bool = True,
        reconnecting: bool = False,
        include_audio_input: bool = True,
        close_code_after_identified: Optional[int] = None,
        expected_audio_request: Optional[Dict[str, str]] = None,
    ) -> None:
        self.authentication_required = authentication_required
        self.valid_upgrade_accept = valid_upgrade_accept
        self.negotiated_subprotocol = negotiated_subprotocol
        self.mask_server_frames = mask_server_frames
        self.request_succeeds = request_succeeds
        self.streaming = streaming
        self.reconnecting = reconnecting
        self.include_audio_input = include_audio_input
        self.close_code_after_identified = close_code_after_identified
        self.expected_audio_request = expected_audio_request or {
            "inputName": "Program Audio"
        }
        self.password = "correct horse battery staple"
        self.salt = "test-salt"
        self.challenge = "test-challenge"
        self.identify_messages: List[Dict[str, Any]] = []
        self.request_count = 0
        self.stream_request_count = 0
        self.accept_count = 0
        self.errors: List[BaseException] = []
        self._stop = threading.Event()
        self._clients: List[socket.socket] = []
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen(8)
        self._listener.settimeout(0.1)
        self.port = self._listener.getsockname()[1]
        self._thread = threading.Thread(
            target=self._serve, name="fake-obs-websocket", daemon=True
        )

    def start(self) -> "FakeOBSServer":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        try:
            self._listener.close()
        except OSError:
            pass
        for client in list(self._clients):
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            client.close()
        self._thread.join(timeout=2.0)

    def __enter__(self) -> "FakeOBSServer":
        return self.start()

    def __exit__(self, *args: Any) -> None:
        self.stop()
        if self.errors:
            raise self.errors[0]

    def _send_json(self, connection: socket.socket, payload: Dict[str, Any]) -> None:
        connection.sendall(
            encode_server_frame(
                json.dumps(payload, separators=(",", ":")).encode("utf-8"),
                masked=self.mask_server_frames,
            )
        )

    def _perform_upgrade(self, connection: socket.socket) -> None:
        request = read_http_headers(connection)
        headers: Dict[str, str] = {}
        for line in request.split("\r\n")[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                headers[name.strip().lower()] = value.strip()
        self.assert_header(headers, "upgrade", "websocket")
        self.assert_header(headers, "sec-websocket-version", "13")
        self.assert_header(
            headers, "sec-websocket-protocol", "obswebsocket.json"
        )
        key = headers["sec-websocket-key"]
        accept = base64.b64encode(
            hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()
        ).decode("ascii")
        if not self.valid_upgrade_accept:
            accept = "incorrect-accept"
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            f"Sec-WebSocket-Protocol: {self.negotiated_subprotocol}\r\n"
            "\r\n"
        ).encode("ascii")
        connection.sendall(response)

    @staticmethod
    def assert_header(
        headers: Dict[str, str], name: str, expected: str
    ) -> None:
        actual = headers.get(name)
        if actual is None or actual.lower() != expected.lower():
            raise AssertionError(
                f"expected {name}: {expected}; received {actual}"
            )

    def _hello(self) -> Dict[str, Any]:
        data: Dict[str, Any] = {
            "obsStudioVersion": "32.2.1",
            "obsWebSocketVersion": "5.6.3",
            "rpcVersion": 1,
        }
        if self.authentication_required:
            data["authentication"] = {
                "salt": self.salt,
                "challenge": self.challenge,
            }
        return {"op": 0, "d": data}

    def _meter_event(self) -> Dict[str, Any]:
        inputs: List[Dict[str, Any]] = []
        if self.include_audio_input:
            inputs.append(
                {
                    "inputName": "Program Audio",
                    "inputUuid": "program-audio-uuid",
                    "inputLevelsMul": [
                        [0.0, 0.0, 0.0],
                        [0.01, 0.02, 0.03],
                    ],
                }
            )
        return {
            "op": 5,
            "d": {
                "eventType": "InputVolumeMeters",
                "eventIntent": OBS_INPUT_VOLUME_METERS,
                "eventData": {"inputs": inputs},
            },
        }

    def _handle(self, connection: socket.socket) -> None:
        connection.settimeout(1.0)
        self._perform_upgrade(connection)
        self._send_json(connection, self._hello())
        opcode, payload = read_client_frame(connection)
        if opcode == 0x8:
            return
        if opcode != 0x1:
            raise AssertionError("Identify must be a text frame")
        identify = json.loads(payload.decode("utf-8"))
        self.identify_messages.append(identify)
        if identify.get("op") != 1:
            raise AssertionError("first client message must be Identify")
        identify_data = identify.get("d", {})
        if identify_data.get("rpcVersion") != 1:
            raise AssertionError("client did not request RPC version 1")
        if identify_data.get("eventSubscriptions") != OBS_EVENT_SUBSCRIPTIONS:
            raise AssertionError("client event subscriptions are incorrect")
        if self.authentication_required:
            expected = obs_authentication_string(
                self.password, self.salt, self.challenge
            )
            if identify_data.get("authentication") != expected:
                connection.sendall(
                    encode_server_frame(
                        struct.pack("!H", 4009) + b"Authentication failed",
                        opcode=0x8,
                    )
                )
                return
        self._send_json(
            connection,
            {"op": 2, "d": {"negotiatedRpcVersion": 1}},
        )
        if self.close_code_after_identified is not None:
            connection.sendall(
                encode_server_frame(
                    struct.pack("!H", self.close_code_after_identified)
                    + b"session invalidated",
                    opcode=0x8,
                )
            )
            return
        connection.settimeout(0.1)
        while not self._stop.is_set():
            try:
                opcode, payload = read_client_frame(connection)
            except socket.timeout:
                continue
            except (EOFError, OSError):
                return
            if opcode == 0x8:
                return
            if opcode == 0xA:
                continue
            if opcode != 0x1:
                raise AssertionError("OBS request must be a text frame")
            request = json.loads(payload.decode("utf-8"))
            if request.get("op") != 6:
                raise AssertionError("expected OBS Request operation")
            data = request["d"]
            self.request_count += 1
            self._send_json(connection, self._meter_event())
            status = (
                {"result": True, "code": 100}
                if self.request_succeeds
                else {
                    "result": False,
                    "code": 500,
                    "comment": "test request failure",
                }
            )
            if data["requestType"] == "GetStreamStatus":
                self.stream_request_count += 1
                response_data: Dict[str, Any] = {
                    "outputActive": self.streaming,
                    "outputReconnecting": self.reconnecting,
                    "outputTimecode": (
                        f"00:00:{self.stream_request_count:02d}.000"
                    ),
                    "outputDuration": 1000 * self.stream_request_count,
                    "outputCongestion": 0.0,
                    "outputBytes": 4096 * self.stream_request_count,
                    "outputSkippedFrames": 0,
                    "outputTotalFrames": 60 * self.stream_request_count,
                }
            elif data["requestType"] == "GetInputAudioTracks":
                if data.get("requestData") != self.expected_audio_request:
                    raise AssertionError(
                        "GetInputAudioTracks was not bound to the configured input"
                    )
                response_data = {
                    "inputAudioTracks": {
                        "1": True,
                        "2": False,
                        "3": False,
                        "4": False,
                        "5": False,
                        "6": False,
                    }
                }
            else:
                raise AssertionError(
                    f"unexpected OBS request {data['requestType']}"
                )
            self._send_json(
                connection,
                {
                    "op": 7,
                    "d": {
                        "requestType": data["requestType"],
                        "requestId": data["requestId"],
                        "requestStatus": status,
                        "responseData": response_data,
                    },
                },
            )

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _address = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.accept_count += 1
            self._clients.append(connection)
            try:
                self._handle(connection)
            except (EOFError, ConnectionError, OSError):
                if not self._stop.is_set():
                    self.errors.append(sys.exc_info()[1] or RuntimeError("socket error"))
            except BaseException as error:
                self.errors.append(error)
            finally:
                try:
                    connection.close()
                except OSError:
                    pass
                if connection in self._clients:
                    self._clients.remove(connection)


def make_session(
    server: FakeOBSServer,
    *,
    password: Optional[str] = None,
    require_authentication: bool = True,
) -> OBSProtocolSession:
    return OBSProtocolSession(
        "127.0.0.1",
        server.port,
        1.0,
        lambda: server.password if password is None else password,
        require_authentication=require_authentication,
    )


class ConfigurationTests(unittest.TestCase):
    def test_loopback_validation_rejects_remote_and_dns_hosts(self) -> None:
        self.assertEqual(validate_loopback_host("127.0.0.1", "host"), "127.0.0.1")
        self.assertEqual(validate_loopback_host("::1", "host"), "::1")
        self.assertEqual(validate_loopback_host("localhost", "host"), "localhost")
        for value in ("0.0.0.0", "192.168.1.50", "obs.local", ""):
            with self.subTest(value=value), self.assertRaises(ConfigurationError):
                validate_loopback_host(value, "host")

    def test_audio_selector_requires_exactly_one_bounded_identity(self) -> None:
        self.assertEqual(AudioInputSelector(name="Program Audio").label, "Program Audio")
        self.assertEqual(
            AudioInputSelector(uuid="program-uuid").label,
            "UUID program-uuid",
        )
        for values in (
            {},
            {"name": "a", "uuid": "b"},
            {"name": ""},
            {"uuid": "x" * 513},
            {"name": "Program\nAudio"},
        ):
            with self.subTest(values=values), self.assertRaises(ConfigurationError):
                AudioInputSelector(**values)

    def test_private_password_file_rejects_broad_mode_symlink_and_bad_content(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            password = root / "password"
            password.write_text("correct horse\n", encoding="utf-8")
            os.chmod(password, 0o600)
            self.assertEqual(read_private_secret(password), "correct horse")
            password.write_text(" correct horse \n", encoding="utf-8")
            self.assertEqual(read_private_secret(password), " correct horse ")

            os.chmod(password, 0o640)
            with self.assertRaises(ConfigurationError):
                read_private_secret(password)
            os.chmod(password, 0o600)

            link = root / "link"
            link.symlink_to(password)
            with self.assertRaises(OSError):
                read_private_secret(link)

            password.write_text("line one\nline two\n", encoding="utf-8")
            with self.assertRaises(ConfigurationError):
                read_private_secret(password)

            password.write_bytes(b"x" * 4097)
            with self.assertRaises(ConfigurationError):
                read_private_secret(password)

    def test_authentication_matches_official_protocol_example(self) -> None:
        result = obs_authentication_string(
            "supersecretpassword",
            "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
            "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY=",
        )
        self.assertEqual(
            result,
            "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=",
        )


class EncoderHealthStateTests(unittest.TestCase):
    def make_state(self) -> EncoderHealthState:
        return EncoderHealthState(
            AudioInputSelector(name="Program Audio"),
            maximum_status_age_ms=3000,
            maximum_meter_age_ms=1000,
        )

    def connect_and_stream(self, state: EncoderHealthState) -> None:
        state.mark_connected(True, "32.2.1", "5.6.3")
        state.update_stream_status(
            {
                "outputActive": True,
                "outputReconnecting": False,
                "outputBytes": 1000,
                "outputTotalFrames": 60,
                "outputSkippedFrames": 0,
                "outputDuration": 1000,
                "outputCongestion": 0.0,
            }
        )
        state.update_stream_status(
            {
                "outputActive": True,
                "outputReconnecting": False,
                "outputBytes": 2000,
                "outputTotalFrames": 120,
                "outputSkippedFrames": 0,
                "outputDuration": 2000,
                "outputCongestion": 0.0,
            }
        )
        state.update_audio_tracks(
            {
                "1": True,
                "2": False,
                "3": False,
                "4": False,
                "5": False,
                "6": False,
            }
        )

    def meter(self, state: EncoderHealthState, peak: float = 0.0) -> None:
        state.update_volume_meters(
            [
                {
                    "inputName": "Program Audio",
                    "inputUuid": "program-uuid",
                    "inputLevelsMul": [[0.0, peak, peak]],
                }
            ]
        )

    def test_fresh_exact_carrier_is_healthy_even_during_program_silence(self) -> None:
        state = self.make_state()
        self.connect_and_stream(state)
        self.meter(state, peak=0.0)

        payload = state.payload()

        self.assertTrue(payload["healthy"])
        self.assertTrue(payload["streaming"])
        self.assertTrue(payload["audioActive"])
        self.assertEqual(payload["peakDbfs"], -120.0)
        self.assertEqual(payload["formatVersion"], FORMAT_VERSION)
        self.assertEqual(payload["kind"], HEALTH_KIND)
        self.assertIn("carrier fresh", payload["detail"])

    def test_wrong_or_inactive_audio_input_fails_closed(self) -> None:
        state = self.make_state()
        self.connect_and_stream(state)
        state.update_volume_meters(
            [
                {
                    "inputName": "Other Audio",
                    "inputUuid": "other-audio-uuid",
                    "inputLevelsMul": [[0.1, 0.2, 0.3]],
                }
            ]
        )

        payload = state.payload()

        self.assertFalse(payload["healthy"])
        self.assertFalse(payload["audioActive"])
        self.assertIn("not active", payload["detail"])

    def test_stale_status_or_meter_fails_closed(self) -> None:
        state = self.make_state()
        self.connect_and_stream(state)
        self.meter(state, peak=0.1)
        fresh = state.payload()
        timestamp = fresh["timestampMs"]

        stale_status = state.payload(now_ms=timestamp + 4000)

        self.assertFalse(stale_status["healthy"])
        self.assertFalse(stale_status["streaming"])
        self.assertFalse(stale_status["audioActive"])
        self.assertIn("stream status is stale", stale_status["detail"])

    def test_reconnecting_or_unauthenticated_session_fails_closed(self) -> None:
        state = self.make_state()
        state.mark_connected(False, "32.2.1", "5.6.3")
        state.update_stream_status(
            {
                "outputActive": True,
                "outputReconnecting": False,
                "outputBytes": 1000,
                "outputTotalFrames": 60,
                "outputSkippedFrames": 0,
                "outputDuration": 1000,
                "outputCongestion": 0.0,
            }
        )
        self.meter(state, peak=0.2)
        self.assertFalse(state.payload()["healthy"])
        self.assertIn("not authenticated", state.payload()["detail"])

        state.mark_connected(True, "32.2.1", "5.6.3")
        state.update_stream_status(
            {
                "outputActive": True,
                "outputReconnecting": True,
                "outputBytes": 1000,
                "outputTotalFrames": 60,
                "outputSkippedFrames": 0,
                "outputDuration": 1000,
                "outputCongestion": 0.0,
            }
        )
        self.meter(state, peak=0.2)
        self.assertFalse(state.payload()["healthy"])
        self.assertIn("reconnecting", state.payload()["detail"])

    def test_stalled_dirty_or_unrouted_encoder_interval_fails_closed(self) -> None:
        state = self.make_state()
        state.mark_connected(True, "32.2.1", "5.6.3")
        baseline = {
            "outputActive": True,
            "outputReconnecting": False,
            "outputBytes": 1000,
            "outputTotalFrames": 60,
            "outputSkippedFrames": 0,
            "outputDuration": 1000,
            "outputCongestion": 0.0,
        }
        state.update_stream_status(baseline)
        state.update_audio_tracks({"1": True})
        self.meter(state, peak=0.2)
        self.assertFalse(state.payload()["healthy"])
        self.assertIn("not advancing", state.payload()["detail"])

        state.update_stream_status(
            {
                **baseline,
                "outputBytes": 2000,
                "outputTotalFrames": 120,
                "outputSkippedFrames": 1,
                "outputDuration": 2000,
            }
        )
        self.assertFalse(state.payload()["healthy"])
        self.assertIn("interval is unhealthy", state.payload()["detail"])

        state.update_stream_status(
            {
                **baseline,
                "outputBytes": 3000,
                "outputTotalFrames": 180,
                "outputSkippedFrames": 1,
                "outputDuration": 3000,
            }
        )
        state.update_audio_tracks({"1": False})
        self.assertFalse(state.payload()["healthy"])
        self.assertIn("not assigned", state.payload()["detail"])

    def test_malformed_audio_track_or_stream_counter_data_is_rejected(self) -> None:
        state = self.make_state()
        for tracks in (None, {"0": True}, {"1": "yes"}, {}):
            with self.subTest(tracks=tracks), self.assertRaises(
                WebSocketProtocolError
            ):
                state.update_audio_tracks(tracks)
        with self.assertRaises(WebSocketProtocolError):
            state.update_stream_status(
                {
                    "outputActive": True,
                    "outputReconnecting": False,
                    "outputBytes": -1,
                    "outputTotalFrames": 0,
                    "outputSkippedFrames": 0,
                    "outputDuration": 0,
                    "outputCongestion": 0.0,
                }
            )

    def test_malformed_or_duplicate_meter_data_is_rejected(self) -> None:
        state = self.make_state()
        bad_inputs: List[Any] = [
            None,
            [{}],
            [
                {
                    "inputName": "Program Audio",
                    "inputLevelsMul": [],
                }
            ],
            [
                {
                    "inputName": "Program Audio",
                    "inputLevelsMul": [[0.0, float("nan"), 0.0]],
                }
            ],
            [
                {
                    "inputName": "Program Audio",
                    "inputLevelsMul": [[0.0, 0.0, 0.0]],
                },
                {
                    "inputName": "Program Audio",
                    "inputLevelsMul": [[0.0, 0.0, 0.0]],
                },
            ],
        ]
        for inputs in bad_inputs:
            with self.subTest(inputs=inputs), self.assertRaises(
                WebSocketProtocolError
            ):
                state.update_volume_meters(inputs)

    def test_disconnect_clears_previous_healthy_state_immediately(self) -> None:
        state = self.make_state()
        self.connect_and_stream(state)
        self.meter(state, peak=0.1)
        self.assertTrue(state.payload()["healthy"])

        state.mark_disconnected("OBS process exited")

        payload = state.payload()
        self.assertFalse(payload["healthy"])
        self.assertFalse(payload["streaming"])
        self.assertFalse(payload["audioActive"])
        self.assertEqual(payload["detail"], "OBS process exited")

    def test_stream_stop_or_reconnect_event_fails_health_immediately(self) -> None:
        state = self.make_state()
        self.connect_and_stream(state)
        self.meter(state, peak=0.1)
        self.assertTrue(state.payload()["healthy"])

        state.update_stream_event(False, "OBS_WEBSOCKET_OUTPUT_STOPPED")
        stopped = state.payload()
        self.assertFalse(stopped["healthy"])
        self.assertFalse(stopped["streaming"])
        self.assertIn("not active", stopped["detail"])

        self.connect_and_stream(state)
        self.meter(state, peak=0.1)
        state.update_stream_event(True, "OBS_WEBSOCKET_OUTPUT_RECONNECTING")
        reconnecting = state.payload()
        self.assertFalse(reconnecting["healthy"])
        self.assertFalse(reconnecting["streaming"])
        self.assertIn("reconnecting", reconnecting["detail"])

    def test_contract_timestamp_uses_oldest_required_observation(self) -> None:
        state = self.make_state()
        stream_status = {
            "outputActive": True,
            "outputReconnecting": False,
            "outputBytes": 1000,
            "outputTotalFrames": 60,
            "outputSkippedFrames": 0,
            "outputDuration": 1000,
            "outputCongestion": 0.0,
        }
        with mock.patch(
            "obs_health_bridge.epoch_ms",
            side_effect=[1100, 1200, 1300, 1400, 1500],
        ):
            state.mark_connected(True, "32.2.1", "5.6.3")
            state.update_stream_status(stream_status)
            state.update_audio_tracks({"1": True})
            state.update_stream_status(
                {
                    **stream_status,
                    "outputBytes": 2000,
                    "outputTotalFrames": 120,
                    "outputDuration": 2000,
                }
            )
            self.meter(state, peak=0.1)

        payload = state.payload(now_ms=1600)
        self.assertTrue(payload["healthy"])
        self.assertEqual(payload["timestampMs"], 1300)


class OBSProtocolTests(unittest.TestCase):
    def test_authenticated_session_requests_stream_and_receives_meter(self) -> None:
        with FakeOBSServer() as server:
            session = make_session(server)
            session.connect()
            events: List[Dict[str, Any]] = []
            response = session.request("GetStreamStatus", events.append)
            session.close()

            self.assertTrue(session.authenticated)
            self.assertEqual(session.obs_studio_version, "32.2.1")
            self.assertTrue(response["outputActive"])
            self.assertFalse(response["outputReconnecting"])
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["d"]["eventType"], "InputVolumeMeters")
            identify_data = server.identify_messages[0]["d"]
            self.assertEqual(
                identify_data["eventSubscriptions"],
                OBS_INPUT_EVENTS
                | OBS_OUTPUT_EVENTS
                | OBS_INPUT_VOLUME_METERS,
            )

    def test_authentication_failure_is_never_accepted(self) -> None:
        with FakeOBSServer() as server:
            session = make_session(server, password="wrong password")
            with self.assertRaises(Exception):
                session.connect()
            self.assertFalse(session.authenticated)
            session.close()

    def test_production_session_rejects_unauthenticated_obs(self) -> None:
        with FakeOBSServer(authentication_required=False) as server:
            session = make_session(server, require_authentication=True)
            with self.assertRaises(ConfigurationError):
                session.connect()
            session.close()

    def test_explicit_rehearsal_session_can_negotiate_without_auth(self) -> None:
        with FakeOBSServer(authentication_required=False) as server:
            session = make_session(server, require_authentication=False)
            session.connect()
            self.assertFalse(session.authenticated)
            session.close()

    def test_upgrade_accept_and_subprotocol_are_verified(self) -> None:
        cases = [
            {"valid_upgrade_accept": False},
            {"negotiated_subprotocol": "other.protocol"},
        ]
        for options in cases:
            with self.subTest(options=options), FakeOBSServer(**options) as server:
                session = make_session(server)
                with self.assertRaises(WebSocketProtocolError):
                    session.connect()
                session.close()

    def test_masked_server_frame_is_rejected(self) -> None:
        with FakeOBSServer(mask_server_frames=True) as server:
            session = make_session(server)
            with self.assertRaises(WebSocketProtocolError):
                session.connect()
            session.close()

    def test_unsuccessful_stream_request_is_rejected(self) -> None:
        with FakeOBSServer(request_succeeds=False) as server:
            session = make_session(server)
            session.connect()
            with self.assertRaisesRegex(
                WebSocketProtocolError, "code 500"
            ):
                session.request("GetStreamStatus", lambda _event: None)
            session.close()

    def test_uuid_input_selector_is_bound_to_track_request(self) -> None:
        expected_request = {"inputUuid": "program-audio-uuid"}
        with FakeOBSServer(
            expected_audio_request=expected_request
        ) as server:
            session = make_session(server)
            session.connect()
            response = session.request(
                "GetInputAudioTracks",
                lambda _event: None,
                expected_request,
            )
            session.close()

            self.assertTrue(response["inputAudioTracks"]["1"])


class MonitorAndHTTPTests(unittest.TestCase):
    def test_monitor_recovers_health_then_fails_on_obs_disconnect(self) -> None:
        server = FakeOBSServer().start()
        selector = AudioInputSelector(name="Program Audio")
        state = EncoderHealthState(
            selector,
            maximum_status_age_ms=1000,
            maximum_meter_age_ms=1000,
        )

        def session_factory() -> OBSProtocolSession:
            return make_session(server)

        stop_event = threading.Event()
        monitor = OBSMonitor(
            state,
            session_factory,
            poll_interval_seconds=0.25,
            maximum_reconnect_seconds=0.25,
        )
        thread = threading.Thread(
            target=monitor.run, args=(stop_event,), daemon=True
        )
        thread.start()
        try:
            self.assertTrue(wait_until(lambda: state.payload()["healthy"]))
            self.assertGreaterEqual(server.request_count, 1)
            server.stop()
            self.assertTrue(
                wait_until(lambda: not state.payload()["connected"])
            )
            self.assertFalse(state.payload()["healthy"])
        finally:
            stop_event.set()
            thread.join(timeout=2.0)

    def test_session_invalidation_never_auto_reconnects(self) -> None:
        with FakeOBSServer(close_code_after_identified=4011) as server:
            state = EncoderHealthState(
                AudioInputSelector(name="Program Audio")
            )

            def session_factory() -> OBSProtocolSession:
                return make_session(server)

            stop_event = threading.Event()
            monitor = OBSMonitor(
                state,
                session_factory,
                poll_interval_seconds=0.25,
                maximum_reconnect_seconds=0.25,
            )
            thread = threading.Thread(
                target=monitor.run, args=(stop_event,), daemon=True
            )
            thread.start()
            try:
                self.assertTrue(
                    wait_until(
                        lambda: "4011" in state.payload()["detail"]
                    )
                )
                time.sleep(0.4)
                self.assertEqual(server.accept_count, 1)
            finally:
                stop_event.set()
                thread.join(timeout=2.0)

    def test_health_http_contract_is_no_store_and_loopback_only(self) -> None:
        state = EncoderHealthState(
            AudioInputSelector(name="Program Audio")
        )
        state.mark_connected(True, "32.2.1", "5.6.3")
        state.update_stream_status(
            {
                "outputActive": True,
                "outputReconnecting": False,
                "outputBytes": 1000,
                "outputTotalFrames": 60,
                "outputSkippedFrames": 0,
                "outputDuration": 1000,
                "outputCongestion": 0.0,
            }
        )
        state.update_stream_status(
            {
                "outputActive": True,
                "outputReconnecting": False,
                "outputBytes": 2000,
                "outputTotalFrames": 120,
                "outputSkippedFrames": 0,
                "outputDuration": 2000,
                "outputCongestion": 0.0,
            }
        )
        state.update_audio_tracks(
            {
                "1": True,
                "2": False,
                "3": False,
                "4": False,
                "5": False,
                "6": False,
            }
        )
        state.update_volume_meters(
            [
                {
                    "inputName": "Program Audio",
                    "inputUuid": "program-audio-uuid",
                    "inputLevelsMul": [[0.01, 0.02, 0.03]],
                }
            ]
        )
        server = HealthHTTPServer(
            ("127.0.0.1", 0), make_health_handler(state)
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/health"
            with urllib.request.urlopen(url, timeout=1.0) as response:
                body = json.load(response)
                self.assertEqual(response.status, 200)
                self.assertEqual(
                    response.headers["Content-Type"], "application/json"
                )
                self.assertIn("no-store", response.headers["Cache-Control"])
                self.assertEqual(
                    response.headers["X-Content-Type-Options"], "nosniff"
                )
            self.assertTrue(body["healthy"])
            self.assertTrue(body["streaming"])
            self.assertTrue(body["audioActive"])
            self.assertIsInstance(body["timestampMs"], int)

            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{server.server_port}/other",
                    timeout=1.0,
                )
            self.assertEqual(raised.exception.code, 404)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
