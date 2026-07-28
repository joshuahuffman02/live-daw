#!/usr/bin/env python3
"""Fail-closed OBS WebSocket v5 to AutoMix encoder-health bridge.

The bridge uses only the Python 3 standard library. It connects to an
authenticated OBS WebSocket server on loopback, polls GetStreamStatus, observes
InputVolumeMeters for one explicitly configured program-audio input, and serves
the versioned AutoMix stream-health JSON contract on loopback.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import math
import os
import secrets
import signal
import socket
import socketserver
import stat
import struct
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple


FORMAT_VERSION = 1
HEALTH_KIND = "automix-obs-encoder-health"
OBS_RPC_VERSION = 1
OBS_INPUT_EVENTS = 1 << 3
OBS_OUTPUT_EVENTS = 1 << 6
OBS_INPUT_VOLUME_METERS = 1 << 16
OBS_EVENT_SUBSCRIPTIONS = (
    OBS_INPUT_EVENTS | OBS_OUTPUT_EVENTS | OBS_INPUT_VOLUME_METERS
)
MAX_HTTP_HEADERS_BYTES = 16 * 1024
MAX_WEBSOCKET_PAYLOAD_BYTES = 1024 * 1024
MAX_PASSWORD_BYTES = 4 * 1024
MAX_SIGNED_TIMESTAMP_MS = (1 << 63) - 1
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def epoch_ms() -> int:
    return int(time.time() * 1000.0)


class ConfigurationError(ValueError):
    pass


class WebSocketProtocolError(RuntimeError):
    pass


class WebSocketClosed(RuntimeError):
    def __init__(self, code: Optional[int], reason: str) -> None:
        self.code = code
        self.reason = reason
        detail = f"WebSocket closed ({code})" if code is not None else "WebSocket closed"
        if reason:
            detail += f": {reason}"
        super().__init__(detail)


def require_range(
    value: float, minimum: float, maximum: float, label: str
) -> float:
    if not math.isfinite(value) or value < minimum or value > maximum:
        raise ConfigurationError(
            f"{label} must be between {minimum:g} and {maximum:g}"
        )
    return value


def validate_port(value: int, label: str) -> int:
    if isinstance(value, bool) or value < 1 or value > 65535:
        raise ConfigurationError(f"{label} must be between 1 and 65535")
    return value


def validate_loopback_host(value: str, label: str) -> str:
    host = value.strip()
    if not host:
        raise ConfigurationError(f"{label} must not be empty")
    if host.lower() == "localhost":
        return host
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        raise ConfigurationError(
            f"{label} must be localhost or a numeric loopback address"
        ) from error
    if not address.is_loopback:
        raise ConfigurationError(f"{label} must resolve only to loopback")
    return host


def read_private_secret(path: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ConfigurationError("OBS password path must be a regular file")
        if info.st_mode & 0o077:
            raise ConfigurationError(
                "OBS password file must not be group/world accessible"
            )
        if info.st_size <= 0 or info.st_size > MAX_PASSWORD_BYTES:
            raise ConfigurationError("OBS password file size is invalid")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            raw = stream.read(MAX_PASSWORD_BYTES + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(raw) > MAX_PASSWORD_BYTES:
        raise ConfigurationError("OBS password file is too large")
    try:
        secret = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ConfigurationError("OBS password file must contain UTF-8") from error
    if secret.endswith("\n"):
        secret = secret[:-1]
        if secret.endswith("\r"):
            secret = secret[:-1]
    if not secret or "\x00" in secret or "\r" in secret or "\n" in secret:
        raise ConfigurationError(
            "OBS password file must contain one non-empty line"
        )
    return secret


def obs_authentication_string(password: str, salt: str, challenge: str) -> str:
    if not password or not salt or not challenge:
        raise WebSocketProtocolError("OBS authentication challenge is incomplete")
    secret_digest = hashlib.sha256((password + salt).encode("utf-8")).digest()
    secret = base64.b64encode(secret_digest).decode("ascii")
    authentication_digest = hashlib.sha256(
        (secret + challenge).encode("utf-8")
    ).digest()
    return base64.b64encode(authentication_digest).decode("ascii")


class SocketBuffer:
    def __init__(self, connection: socket.socket) -> None:
        self.connection = connection
        self.buffer = bytearray()

    def read_exact(self, size: int) -> bytes:
        if size < 0:
            raise WebSocketProtocolError("negative WebSocket read size")
        while len(self.buffer) < size:
            chunk = self.connection.recv(max(4096, size - len(self.buffer)))
            if not chunk:
                raise WebSocketClosed(None, "peer disconnected")
            self.buffer.extend(chunk)
        result = bytes(self.buffer[:size])
        del self.buffer[:size]
        return result

    def read_until(self, marker: bytes, maximum_bytes: int) -> bytes:
        while True:
            marker_index = self.buffer.find(marker)
            if marker_index >= 0:
                end = marker_index + len(marker)
                result = bytes(self.buffer[:end])
                del self.buffer[:end]
                return result
            if len(self.buffer) >= maximum_bytes:
                raise WebSocketProtocolError("HTTP upgrade headers are too large")
            chunk = self.connection.recv(4096)
            if not chunk:
                raise WebSocketClosed(None, "peer disconnected during HTTP upgrade")
            self.buffer.extend(chunk)
            if len(self.buffer) > maximum_bytes:
                raise WebSocketProtocolError("HTTP upgrade headers are too large")


def _parse_upgrade_headers(raw: bytes) -> Tuple[str, Dict[str, List[str]]]:
    try:
        text = raw.decode("iso-8859-1")
    except UnicodeDecodeError as error:
        raise WebSocketProtocolError("HTTP upgrade headers are invalid") from error
    lines = text.split("\r\n")
    if not lines or not lines[0]:
        raise WebSocketProtocolError("HTTP upgrade status is missing")
    headers: Dict[str, List[str]] = {}
    for line in lines[1:]:
        if not line:
            continue
        if line[:1] in (" ", "\t") or ":" not in line:
            raise WebSocketProtocolError("HTTP upgrade header is malformed")
        name, value = line.split(":", 1)
        normalized = name.strip().lower()
        if not normalized:
            raise WebSocketProtocolError("HTTP upgrade header name is empty")
        headers.setdefault(normalized, []).append(value.strip())
    return lines[0], headers


def _single_header(headers: Dict[str, List[str]], name: str) -> str:
    values = headers.get(name, [])
    if len(values) != 1 or not values[0]:
        raise WebSocketProtocolError(f"HTTP upgrade {name} header is invalid")
    return values[0]


class WebSocketConnection:
    def __init__(self, connection: socket.socket, buffer: SocketBuffer) -> None:
        self.connection = connection
        self.buffer = buffer
        self.closed = False
        self.transport_closed = False

    @classmethod
    def connect(
        cls, host: str, port: int, timeout_seconds: float
    ) -> "WebSocketConnection":
        host = validate_loopback_host(host, "OBS WebSocket host")
        validate_port(port, "OBS WebSocket port")
        require_range(timeout_seconds, 0.1, 10.0, "OBS connection timeout")
        connection = socket.create_connection((host, port), timeout=timeout_seconds)
        try:
            peer_host = connection.getpeername()[0]
            if not ipaddress.ip_address(peer_host).is_loopback:
                raise WebSocketProtocolError(
                    "OBS WebSocket connection escaped loopback"
                )
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            connection.settimeout(timeout_seconds)
            key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
            host_header = f"[{host}]" if ":" in host and not host.startswith("[") else host
            request = (
                "GET / HTTP/1.1\r\n"
                f"Host: {host_header}:{port}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "Sec-WebSocket-Protocol: obswebsocket.json\r\n"
                "\r\n"
            ).encode("ascii")
            connection.sendall(request)
            buffer = SocketBuffer(connection)
            raw_headers = buffer.read_until(b"\r\n\r\n", MAX_HTTP_HEADERS_BYTES)
            status, headers = _parse_upgrade_headers(raw_headers)
            parts = status.split(" ", 2)
            if len(parts) < 2 or parts[0] != "HTTP/1.1" or parts[1] != "101":
                raise WebSocketProtocolError(
                    f"OBS WebSocket upgrade returned {status}"
                )
            upgrade = _single_header(headers, "upgrade").lower()
            if upgrade != "websocket":
                raise WebSocketProtocolError(
                    "OBS WebSocket upgrade response is missing websocket"
                )
            connection_tokens = {
                token.strip().lower()
                for token in _single_header(headers, "connection").split(",")
            }
            if "upgrade" not in connection_tokens:
                raise WebSocketProtocolError(
                    "OBS WebSocket upgrade response is missing Connection: Upgrade"
                )
            expected_accept = base64.b64encode(
                hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()
            ).decode("ascii")
            if not secrets.compare_digest(
                _single_header(headers, "sec-websocket-accept"),
                expected_accept,
            ):
                raise WebSocketProtocolError(
                    "OBS WebSocket upgrade accept value is invalid"
                )
            if (
                _single_header(headers, "sec-websocket-protocol")
                != "obswebsocket.json"
            ):
                raise WebSocketProtocolError(
                    "OBS WebSocket did not negotiate obswebsocket.json"
                )
            return cls(connection, buffer)
        except Exception:
            connection.close()
            raise

    def close(self) -> None:
        if self.transport_closed:
            return
        if not self.closed:
            try:
                self._send_frame(0x8, struct.pack("!H", 1000))
            except Exception:
                pass
        self.closed = True
        self.transport_closed = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.connection.close()

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self.closed:
            raise WebSocketClosed(None, "connection is closed")
        if len(payload) > MAX_WEBSOCKET_PAYLOAD_BYTES:
            raise WebSocketProtocolError("outbound WebSocket payload is too large")
        first = 0x80 | (opcode & 0x0F)
        length = len(payload)
        if length < 126:
            header = bytes((first, 0x80 | length))
        elif length <= 0xFFFF:
            header = bytes((first, 0x80 | 126)) + struct.pack("!H", length)
        else:
            header = bytes((first, 0x80 | 127)) + struct.pack("!Q", length)
        mask = secrets.token_bytes(4)
        masked = bytes(value ^ mask[index & 3] for index, value in enumerate(payload))
        self.connection.sendall(header + mask + masked)

    def send_json(self, payload: Dict[str, Any]) -> None:
        encoded = json.dumps(
            payload, separators=(",", ":"), ensure_ascii=True
        ).encode("utf-8")
        self._send_frame(0x1, encoded)

    def _receive_frame(self) -> Tuple[bool, int, bytes]:
        first, second = self.buffer.read_exact(2)
        finished = bool(first & 0x80)
        if first & 0x70:
            raise WebSocketProtocolError("WebSocket RSV bits must be zero")
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        if masked:
            raise WebSocketProtocolError("OBS server sent a masked WebSocket frame")
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self.buffer.read_exact(2))[0]
        elif length == 127:
            raw_length = self.buffer.read_exact(8)
            if raw_length[0] & 0x80:
                raise WebSocketProtocolError("WebSocket payload length is invalid")
            length = struct.unpack("!Q", raw_length)[0]
        if length > MAX_WEBSOCKET_PAYLOAD_BYTES:
            raise WebSocketProtocolError("OBS WebSocket payload is too large")
        if opcode >= 0x8 and (not finished or length > 125):
            raise WebSocketProtocolError("WebSocket control frame is malformed")
        return finished, opcode, self.buffer.read_exact(length)

    def receive_json(self, timeout_seconds: float) -> Dict[str, Any]:
        require_range(timeout_seconds, 0.01, 10.0, "WebSocket receive timeout")
        self.connection.settimeout(timeout_seconds)
        fragments = bytearray()
        fragment_opcode: Optional[int] = None
        while True:
            finished, opcode, payload = self._receive_frame()
            if opcode == 0x8:
                if len(payload) == 1:
                    raise WebSocketProtocolError("WebSocket close payload is malformed")
                code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None
                try:
                    reason = payload[2:].decode("utf-8")
                except UnicodeDecodeError as error:
                    raise WebSocketProtocolError(
                        "WebSocket close reason is invalid UTF-8"
                    ) from error
                self.closed = True
                raise WebSocketClosed(code, reason)
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode == 0x2:
                raise WebSocketProtocolError(
                    "OBS sent binary data for obswebsocket.json"
                )
            if opcode == 0x1:
                if fragment_opcode is not None:
                    raise WebSocketProtocolError("nested WebSocket data frame")
                fragment_opcode = opcode
                fragments.extend(payload)
            elif opcode == 0x0:
                if fragment_opcode is None:
                    raise WebSocketProtocolError(
                        "unexpected WebSocket continuation frame"
                    )
                fragments.extend(payload)
            else:
                raise WebSocketProtocolError(
                    f"unsupported WebSocket opcode {opcode}"
                )
            if len(fragments) > MAX_WEBSOCKET_PAYLOAD_BYTES:
                raise WebSocketProtocolError("OBS WebSocket message is too large")
            if not finished:
                continue
            try:
                value = json.loads(fragments.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise WebSocketProtocolError(
                    "OBS WebSocket message is not valid UTF-8 JSON"
                ) from error
            if not isinstance(value, dict):
                raise WebSocketProtocolError(
                    "OBS WebSocket message must be a JSON object"
                )
            return value


def _required_dict(value: Any, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise WebSocketProtocolError(f"{label} must be an object")
    return value


def _required_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise WebSocketProtocolError(f"{label} must be an integer")
    return value


def _required_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise WebSocketProtocolError(f"{label} must be a boolean")
    return value


def _required_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise WebSocketProtocolError(f"{label} must be a non-empty string")
    return value


def _required_nonnegative_int(value: Any, label: str) -> int:
    result = _required_int(value, label)
    if result < 0 or result > MAX_SIGNED_TIMESTAMP_MS:
        raise WebSocketProtocolError(f"{label} must be a nonnegative integer")
    return result


def _required_number(
    value: Any, label: str, minimum: float, maximum: float
) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
    ):
        raise WebSocketProtocolError(f"{label} must be a finite number")
    result = float(value)
    if result < minimum or result > maximum:
        raise WebSocketProtocolError(
            f"{label} must be between {minimum:g} and {maximum:g}"
        )
    return result


class OBSProtocolSession:
    def __init__(
        self,
        host: str,
        port: int,
        timeout_seconds: float,
        password_loader: Callable[[], Optional[str]],
        require_authentication: bool,
    ) -> None:
        self.host = validate_loopback_host(host, "OBS WebSocket host")
        self.port = validate_port(port, "OBS WebSocket port")
        self.timeout_seconds = require_range(
            timeout_seconds, 0.1, 10.0, "OBS WebSocket timeout"
        )
        self.password_loader = password_loader
        self.require_authentication = require_authentication
        self.connection: Optional[WebSocketConnection] = None
        self.authenticated = False
        self.obs_studio_version = ""
        self.obs_websocket_version = ""

    def connect(self) -> None:
        self.authenticated = False
        connection = WebSocketConnection.connect(
            self.host, self.port, self.timeout_seconds
        )
        try:
            hello = connection.receive_json(self.timeout_seconds)
            if _required_int(hello.get("op"), "OBS Hello op") != 0:
                raise WebSocketProtocolError("first OBS message must be Hello")
            hello_data = _required_dict(hello.get("d"), "OBS Hello data")
            rpc_version = _required_int(
                hello_data.get("rpcVersion"), "OBS RPC version"
            )
            if rpc_version < OBS_RPC_VERSION:
                raise WebSocketProtocolError(
                    f"OBS RPC version {rpc_version} does not support version 1"
                )
            self.obs_studio_version = _required_string(
                hello_data.get("obsStudioVersion"), "OBS Studio version"
            )
            self.obs_websocket_version = _required_string(
                hello_data.get("obsWebSocketVersion"), "OBS WebSocket version"
            )
            authentication_info = hello_data.get("authentication")
            identify_data: Dict[str, Any] = {
                "rpcVersion": OBS_RPC_VERSION,
                "eventSubscriptions": OBS_EVENT_SUBSCRIPTIONS,
            }
            if authentication_info is not None:
                challenge_data = _required_dict(
                    authentication_info, "OBS authentication challenge"
                )
                password = self.password_loader()
                if not password:
                    raise ConfigurationError(
                        "OBS requires authentication but no private password file is configured"
                    )
                identify_data["authentication"] = obs_authentication_string(
                    password,
                    _required_string(
                        challenge_data.get("salt"), "OBS authentication salt"
                    ),
                    _required_string(
                        challenge_data.get("challenge"),
                        "OBS authentication challenge",
                    ),
                )
                authenticated = True
            else:
                if self.require_authentication:
                    raise ConfigurationError(
                        "OBS WebSocket authentication is disabled; production monitoring refuses this configuration"
                    )
                authenticated = False
            connection.send_json({"op": 1, "d": identify_data})
            identified = connection.receive_json(self.timeout_seconds)
            if _required_int(identified.get("op"), "OBS Identified op") != 2:
                raise WebSocketProtocolError(
                    "OBS did not acknowledge identification"
                )
            identified_data = _required_dict(
                identified.get("d"), "OBS Identified data"
            )
            if (
                _required_int(
                    identified_data.get("negotiatedRpcVersion"),
                    "OBS negotiated RPC version",
                )
                != OBS_RPC_VERSION
            ):
                raise WebSocketProtocolError(
                    "OBS negotiated an unsupported RPC version"
                )
            self.authenticated = authenticated
            self.connection = connection
        except Exception:
            connection.close()
            raise

    def close(self) -> None:
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def receive(self, timeout_seconds: float) -> Dict[str, Any]:
        if self.connection is None:
            raise WebSocketClosed(None, "OBS session is not connected")
        return self.connection.receive_json(timeout_seconds)

    def request(
        self,
        request_type: str,
        event_handler: Callable[[Dict[str, Any]], None],
        request_data: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        if self.connection is None:
            raise WebSocketClosed(None, "OBS session is not connected")
        request_id = str(uuid.uuid4())
        operation_data: Dict[str, Any] = {
            "requestType": request_type,
            "requestId": request_id,
        }
        if request_data is not None:
            operation_data["requestData"] = request_data
        self.connection.send_json({"op": 6, "d": operation_data})
        deadline = time.monotonic() + self.timeout_seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"OBS {request_type} response timed out")
            message = self.connection.receive_json(remaining)
            operation = _required_int(message.get("op"), "OBS message op")
            if operation == 5:
                event_handler(message)
                continue
            if operation != 7:
                raise WebSocketProtocolError(
                    f"unexpected OBS operation {operation} while awaiting response"
                )
            data = _required_dict(message.get("d"), "OBS response data")
            response_id = _required_string(
                data.get("requestId"), "OBS response requestId"
            )
            if response_id != request_id:
                raise WebSocketProtocolError(
                    "OBS response requestId does not match the request"
                )
            if data.get("requestType") != request_type:
                raise WebSocketProtocolError(
                    "OBS response requestType does not match the request"
                )
            request_status = _required_dict(
                data.get("requestStatus"), "OBS request status"
            )
            result = _required_bool(
                request_status.get("result"), "OBS request result"
            )
            code = _required_int(
                request_status.get("code"), "OBS request status code"
            )
            if not result or code != 100:
                comment = request_status.get("comment")
                suffix = f": {comment}" if isinstance(comment, str) and comment else ""
                raise WebSocketProtocolError(
                    f"OBS {request_type} failed with code {code}{suffix}"
                )
            return _required_dict(
                data.get("responseData"), "OBS response payload"
            )


@dataclass(frozen=True)
class AudioInputSelector:
    name: Optional[str] = None
    uuid: Optional[str] = None

    def __post_init__(self) -> None:
        selected = int(bool(self.name)) + int(bool(self.uuid))
        if selected != 1:
            raise ConfigurationError(
                "configure exactly one OBS audio input name or UUID"
            )
        value = self.name if self.name is not None else self.uuid
        if value is None or not value.strip() or len(value) > 512:
            raise ConfigurationError("OBS audio input identity is invalid")
        if any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ConfigurationError(
                "OBS audio input identity must not contain control characters"
            )

    @property
    def label(self) -> str:
        return self.name if self.name is not None else f"UUID {self.uuid}"

    def matches(self, candidate: Dict[str, Any]) -> bool:
        if self.name is not None:
            return candidate.get("inputName") == self.name
        return candidate.get("inputUuid") == self.uuid

    @property
    def request_data(self) -> Dict[str, str]:
        if self.name is not None:
            return {"inputName": self.name}
        if self.uuid is None:
            raise ConfigurationError("OBS audio input UUID is missing")
        return {"inputUuid": self.uuid}


class EncoderHealthState:
    def __init__(
        self,
        selector: AudioInputSelector,
        audio_track: int = 1,
        maximum_status_age_ms: int = 3000,
        maximum_meter_age_ms: int = 1000,
        production_eligible: bool = True,
    ) -> None:
        self.selector = selector
        self.production_eligible = bool(production_eligible)
        if isinstance(audio_track, bool) or audio_track < 1 or audio_track > 6:
            raise ConfigurationError("OBS audio track must be between 1 and 6")
        self.audio_track = audio_track
        self.maximum_status_age_ms = int(
            require_range(
                float(maximum_status_age_ms),
                250.0,
                15000.0,
                "maximum stream-status age",
            )
        )
        self.maximum_meter_age_ms = int(
            require_range(
                float(maximum_meter_age_ms),
                100.0,
                5000.0,
                "maximum OBS meter age",
            )
        )
        self._lock = threading.Lock()
        self.connected = False
        self.authenticated = False
        self.obs_studio_version = ""
        self.obs_websocket_version = ""
        self.streaming = False
        self.reconnecting = False
        self.status_timestamp_ms = 0
        self.encoder_progressing = False
        self.encoder_interval_clean = False
        self.output_bytes = 0
        self.output_total_frames = 0
        self.output_skipped_frames = 0
        self.output_duration_ms = 0
        self.output_congestion = 0.0
        self.audio_track_enabled = False
        self.track_timestamp_ms = 0
        self.audio_carrier = False
        self.meter_timestamp_ms = 0
        self.peak_dbfs: Optional[float] = None
        self.last_observation_ms = epoch_ms()
        self.failure = "waiting for OBS WebSocket"
        self.session_generation = 0

    def mark_connected(
        self,
        authenticated: bool,
        obs_studio_version: str,
        obs_websocket_version: str,
    ) -> None:
        with self._lock:
            self.connected = True
            self.authenticated = authenticated
            self.obs_studio_version = obs_studio_version
            self.obs_websocket_version = obs_websocket_version
            self.streaming = False
            self.reconnecting = False
            self.status_timestamp_ms = 0
            self.encoder_progressing = False
            self.encoder_interval_clean = False
            self.output_bytes = 0
            self.output_total_frames = 0
            self.output_skipped_frames = 0
            self.output_duration_ms = 0
            self.output_congestion = 0.0
            self.audio_track_enabled = False
            self.track_timestamp_ms = 0
            self.audio_carrier = False
            self.meter_timestamp_ms = 0
            self.peak_dbfs = None
            self.last_observation_ms = epoch_ms()
            self.failure = "waiting for initial OBS stream and meter observations"
            self.session_generation += 1

    def mark_disconnected(self, reason: str) -> None:
        clean_reason = " ".join(reason.split())[:512] or "OBS WebSocket unavailable"
        with self._lock:
            self.connected = False
            self.authenticated = False
            self.streaming = False
            self.reconnecting = False
            self.status_timestamp_ms = 0
            self.encoder_progressing = False
            self.encoder_interval_clean = False
            self.output_bytes = 0
            self.output_total_frames = 0
            self.output_skipped_frames = 0
            self.output_duration_ms = 0
            self.output_congestion = 0.0
            self.audio_track_enabled = False
            self.track_timestamp_ms = 0
            self.audio_carrier = False
            self.meter_timestamp_ms = 0
            self.peak_dbfs = None
            self.last_observation_ms = epoch_ms()
            self.failure = clean_reason

    def update_stream_status(self, payload: Dict[str, Any]) -> None:
        streaming = _required_bool(
            payload.get("outputActive"), "OBS stream outputActive"
        )
        reconnecting = _required_bool(
            payload.get("outputReconnecting"), "OBS stream outputReconnecting"
        )
        output_bytes = _required_nonnegative_int(
            payload.get("outputBytes"), "OBS stream outputBytes"
        )
        output_total_frames = _required_nonnegative_int(
            payload.get("outputTotalFrames"), "OBS stream outputTotalFrames"
        )
        output_skipped_frames = _required_nonnegative_int(
            payload.get("outputSkippedFrames"), "OBS stream outputSkippedFrames"
        )
        output_duration_ms = _required_nonnegative_int(
            payload.get("outputDuration"), "OBS stream outputDuration"
        )
        output_congestion = _required_number(
            payload.get("outputCongestion"),
            "OBS stream outputCongestion",
            0.0,
            1.0,
        )
        timestamp_ms = epoch_ms()
        with self._lock:
            had_baseline = self.status_timestamp_ms > 0
            counters_advance = bool(
                had_baseline
                and output_bytes > self.output_bytes
                and output_total_frames > self.output_total_frames
                and output_duration_ms > self.output_duration_ms
            )
            counters_reset = bool(
                had_baseline
                and (
                    output_bytes < self.output_bytes
                    or output_total_frames < self.output_total_frames
                    or output_skipped_frames < self.output_skipped_frames
                    or output_duration_ms < self.output_duration_ms
                )
            )
            skipped_delta = (
                output_skipped_frames - self.output_skipped_frames
                if had_baseline and not counters_reset
                else 0
            )
            self.streaming = streaming
            self.reconnecting = reconnecting
            self.encoder_progressing = bool(
                streaming and not reconnecting and counters_advance
            )
            self.encoder_interval_clean = bool(
                self.encoder_progressing
                and skipped_delta == 0
                and output_congestion < 0.95
            )
            self.output_bytes = output_bytes
            self.output_total_frames = output_total_frames
            self.output_skipped_frames = output_skipped_frames
            self.output_duration_ms = output_duration_ms
            self.output_congestion = output_congestion
            self.status_timestamp_ms = timestamp_ms
            self.last_observation_ms = timestamp_ms

    def update_stream_event(self, output_active: Any, output_state: Any) -> None:
        streaming = _required_bool(
            output_active, "OBS stream event outputActive"
        )
        state = _required_string(
            output_state, "OBS stream event outputState"
        )
        reconnecting = state == "OBS_WEBSOCKET_OUTPUT_RECONNECTING"
        timestamp_ms = epoch_ms()
        with self._lock:
            self.streaming = streaming
            self.reconnecting = reconnecting
            if not streaming or reconnecting:
                self.encoder_progressing = False
                self.encoder_interval_clean = False
            self.last_observation_ms = timestamp_ms

    def update_audio_tracks(self, tracks: Any) -> None:
        if not isinstance(tracks, dict):
            raise WebSocketProtocolError(
                "OBS inputAudioTracks must be an object"
            )
        for key, value in tracks.items():
            if not isinstance(key, str) or key not in {
                "1",
                "2",
                "3",
                "4",
                "5",
                "6",
            }:
                raise WebSocketProtocolError(
                    "OBS inputAudioTracks contains an invalid track key"
                )
            _required_bool(value, f"OBS audio track {key}")
        selected = tracks.get(str(self.audio_track))
        if selected is None:
            raise WebSocketProtocolError(
                f"OBS inputAudioTracks is missing track {self.audio_track}"
            )
        timestamp_ms = epoch_ms()
        with self._lock:
            self.audio_track_enabled = selected
            self.track_timestamp_ms = timestamp_ms
            self.last_observation_ms = timestamp_ms

    @staticmethod
    def _validated_peak_dbfs(levels: Any) -> float:
        if not isinstance(levels, list) or not levels:
            raise WebSocketProtocolError(
                "OBS program input meter has no channel levels"
            )
        maximum_peak = 0.0
        for channel in levels:
            if not isinstance(channel, list) or len(channel) < 3:
                raise WebSocketProtocolError(
                    "OBS program input meter channel is malformed"
                )
            for value in channel[:3]:
                if (
                    not isinstance(value, (int, float))
                    or isinstance(value, bool)
                    or not math.isfinite(float(value))
                    or float(value) < 0.0
                ):
                    raise WebSocketProtocolError(
                        "OBS program input meter contains an invalid level"
                    )
            maximum_peak = max(maximum_peak, float(channel[1]))
        if maximum_peak <= 0.0:
            return -120.0
        return max(-120.0, min(26.0, 20.0 * math.log10(maximum_peak)))

    def update_volume_meters(self, inputs: Any) -> None:
        if not isinstance(inputs, list):
            raise WebSocketProtocolError(
                "OBS InputVolumeMeters inputs must be an array"
            )
        matching_peak_dbfs: Optional[float] = None
        for candidate in inputs:
            if not isinstance(candidate, dict):
                raise WebSocketProtocolError(
                    "OBS InputVolumeMeters entry must be an object"
                )
            _required_string(
                candidate.get("inputName"), "OBS meter inputName"
            )
            _required_string(
                candidate.get("inputUuid"), "OBS meter inputUuid"
            )
            candidate_peak_dbfs = self._validated_peak_dbfs(
                candidate.get("inputLevelsMul")
            )
            if self.selector.matches(candidate):
                if matching_peak_dbfs is not None:
                    raise WebSocketProtocolError(
                        "OBS InputVolumeMeters contains duplicate configured inputs"
                    )
                matching_peak_dbfs = candidate_peak_dbfs
        timestamp_ms = epoch_ms()
        if matching_peak_dbfs is None:
            with self._lock:
                self.audio_carrier = False
                self.meter_timestamp_ms = timestamp_ms
                self.peak_dbfs = None
                self.last_observation_ms = timestamp_ms
            return
        with self._lock:
            self.audio_carrier = True
            self.meter_timestamp_ms = timestamp_ms
            self.peak_dbfs = matching_peak_dbfs
            self.last_observation_ms = timestamp_ms

    def payload(self, now_ms: Optional[int] = None) -> Dict[str, Any]:
        now = epoch_ms() if now_ms is None else now_ms
        with self._lock:
            connected = self.connected
            authenticated = self.authenticated
            obs_studio_version = self.obs_studio_version
            obs_websocket_version = self.obs_websocket_version
            streaming = self.streaming
            reconnecting = self.reconnecting
            status_timestamp_ms = self.status_timestamp_ms
            encoder_progressing = self.encoder_progressing
            encoder_interval_clean = self.encoder_interval_clean
            output_bytes = self.output_bytes
            output_total_frames = self.output_total_frames
            output_skipped_frames = self.output_skipped_frames
            output_duration_ms = self.output_duration_ms
            output_congestion = self.output_congestion
            audio_track_enabled = self.audio_track_enabled
            track_timestamp_ms = self.track_timestamp_ms
            audio_carrier = self.audio_carrier
            meter_timestamp_ms = self.meter_timestamp_ms
            peak_dbfs = self.peak_dbfs
            last_observation_ms = self.last_observation_ms
            failure = self.failure
            session_generation = self.session_generation

        status_age_ms = (
            now - status_timestamp_ms if status_timestamp_ms > 0 else None
        )
        meter_age_ms = now - meter_timestamp_ms if meter_timestamp_ms > 0 else None
        track_age_ms = now - track_timestamp_ms if track_timestamp_ms > 0 else None
        status_fresh = (
            status_age_ms is not None
            and -5000 <= status_age_ms <= self.maximum_status_age_ms
        )
        meter_fresh = (
            meter_age_ms is not None
            and -5000 <= meter_age_ms <= self.maximum_meter_age_ms
        )
        track_fresh = (
            track_age_ms is not None
            and -5000 <= track_age_ms <= self.maximum_status_age_ms
        )

        if not self.production_eligible:
            detail = (
                "rehearsal/unauthenticated OBS configuration cannot produce "
                "production health"
            )
        elif not connected:
            detail = failure
        elif not authenticated:
            detail = "OBS WebSocket session is not authenticated"
        elif status_timestamp_ms <= 0:
            detail = "waiting for OBS stream status"
        elif not status_fresh:
            detail = "OBS stream status is stale"
        elif not streaming:
            detail = "OBS stream output is not active"
        elif reconnecting:
            detail = "OBS stream output is reconnecting"
        elif not encoder_progressing:
            detail = "OBS encoder byte/frame/duration counters are not advancing"
        elif not encoder_interval_clean:
            detail = (
                "OBS encoder interval is unhealthy: "
                f"skipped={output_skipped_frames}, "
                f"congestion={output_congestion:.3f}"
            )
        elif track_timestamp_ms <= 0:
            detail = (
                f"waiting for OBS track {self.audio_track} routing on "
                f"{self.selector.label}"
            )
        elif not track_fresh:
            detail = (
                f"OBS track routing is stale for {self.selector.label}"
            )
        elif not audio_track_enabled:
            detail = (
                f"{self.selector.label} is not assigned to OBS streaming "
                f"track {self.audio_track}"
            )
        elif meter_timestamp_ms <= 0:
            detail = f"waiting for OBS audio carrier {self.selector.label}"
        elif not meter_fresh:
            detail = f"OBS audio carrier meter is stale for {self.selector.label}"
        elif not audio_carrier:
            detail = f"OBS audio carrier is not active: {self.selector.label}"
        else:
            peak_summary = (
                f"; peak {peak_dbfs:.1f} dBFS"
                if peak_dbfs is not None
                else ""
            )
            detail = (
                f"OBS {obs_studio_version} streaming; "
                f"{self.selector.label} carrier fresh on track "
                f"{self.audio_track}{peak_summary}"
            )

        healthy = bool(
            self.production_eligible
            and connected
            and authenticated
            and status_fresh
            and streaming
            and not reconnecting
            and encoder_progressing
            and encoder_interval_clean
            and track_fresh
            and audio_track_enabled
            and meter_fresh
            and audio_carrier
        )
        required_observation_timestamps = [
            timestamp
            for timestamp in (
                status_timestamp_ms,
                track_timestamp_ms,
                meter_timestamp_ms,
            )
            if timestamp > 0
        ]
        if required_observation_timestamps:
            observation_timestamp_ms = min(required_observation_timestamps)
        else:
            observation_timestamp_ms = last_observation_ms
        observation_timestamp_ms = max(
            1, min(MAX_SIGNED_TIMESTAMP_MS, observation_timestamp_ms)
        )

        return {
            "formatVersion": FORMAT_VERSION,
            "kind": HEALTH_KIND,
            "productionEligible": self.production_eligible,
            "healthy": healthy,
            "streaming": bool(
                streaming
                and status_fresh
                and encoder_progressing
                and encoder_interval_clean
            ),
            "audioActive": bool(audio_carrier and meter_fresh),
            "timestampMs": observation_timestamp_ms,
            "detail": detail,
            "connected": connected,
            "authenticated": authenticated,
            "outputReconnecting": reconnecting,
            "obsStudioVersion": obs_studio_version,
            "obsWebSocketVersion": obs_websocket_version,
            "audioInput": self.selector.label,
            "audioTrack": self.audio_track,
            "audioTrackEnabled": audio_track_enabled,
            "streamStatusAgeMs": status_age_ms,
            "audioTrackAgeMs": track_age_ms,
            "audioMeterAgeMs": meter_age_ms,
            "peakDbfs": peak_dbfs,
            "encoderProgressing": encoder_progressing,
            "encoderIntervalClean": encoder_interval_clean,
            "outputBytes": output_bytes,
            "outputTotalFrames": output_total_frames,
            "outputSkippedFrames": output_skipped_frames,
            "outputDurationMs": output_duration_ms,
            "outputCongestion": output_congestion,
            "sessionGeneration": session_generation,
        }


class OBSMonitor:
    def __init__(
        self,
        state: EncoderHealthState,
        session_factory: Callable[[], OBSProtocolSession],
        poll_interval_seconds: float = 1.0,
        maximum_reconnect_seconds: float = 5.0,
    ) -> None:
        self.state = state
        self.session_factory = session_factory
        self.poll_interval_seconds = require_range(
            poll_interval_seconds, 0.25, 5.0, "OBS status poll interval"
        )
        self.maximum_reconnect_seconds = require_range(
            maximum_reconnect_seconds, 0.25, 30.0, "maximum reconnect delay"
        )

    def _handle_message(self, message: Dict[str, Any]) -> None:
        operation = _required_int(message.get("op"), "OBS message op")
        if operation != 5:
            raise WebSocketProtocolError(
                f"unexpected OBS operation {operation} outside a request"
            )
        data = _required_dict(message.get("d"), "OBS event data")
        event_type = _required_string(
            data.get("eventType"), "OBS event type"
        )
        event_intent = _required_int(
            data.get("eventIntent"), "OBS event intent"
        )
        event_data = _required_dict(
            data.get("eventData"), "OBS event payload"
        )
        if event_type == "InputVolumeMeters":
            if event_intent != OBS_INPUT_VOLUME_METERS:
                raise WebSocketProtocolError(
                    "OBS InputVolumeMeters event intent is invalid"
                )
            self.state.update_volume_meters(event_data.get("inputs"))
        elif event_type == "InputAudioTracksChanged":
            if not event_intent & OBS_INPUT_EVENTS:
                raise WebSocketProtocolError(
                    "OBS InputAudioTracksChanged event intent is invalid"
                )
            if self.state.selector.matches(event_data):
                self.state.update_audio_tracks(
                    event_data.get("inputAudioTracks")
                )
        elif event_type == "StreamStateChanged":
            if not event_intent & OBS_OUTPUT_EVENTS:
                raise WebSocketProtocolError(
                    "OBS StreamStateChanged event intent is invalid"
                )
            # The next GetStreamStatus poll remains authoritative. Recording this
            # as an observation makes a disconnect/stop visible immediately.
            self.state.update_stream_event(
                event_data.get("outputActive"),
                event_data.get("outputState"),
            )

    def _run_session(
        self, session: OBSProtocolSession, stop_event: threading.Event
    ) -> None:
        session.connect()
        self.state.mark_connected(
            session.authenticated,
            session.obs_studio_version,
            session.obs_websocket_version,
        )
        next_poll = 0.0
        while not stop_event.is_set():
            now = time.monotonic()
            if now >= next_poll:
                response = session.request(
                    "GetStreamStatus", self._handle_message
                )
                self.state.update_stream_status(response)
                track_response = session.request(
                    "GetInputAudioTracks",
                    self._handle_message,
                    self.state.selector.request_data,
                )
                self.state.update_audio_tracks(
                    track_response.get("inputAudioTracks")
                )
                next_poll = time.monotonic() + self.poll_interval_seconds
                continue
            wait_seconds = min(0.25, max(0.01, next_poll - now))
            try:
                self._handle_message(session.receive(wait_seconds))
            except socket.timeout:
                pass

    def run(self, stop_event: threading.Event) -> None:
        reconnect_delay = 0.25
        while not stop_event.is_set():
            session = self.session_factory()
            try:
                self._run_session(session, stop_event)
                reconnect_delay = 0.25
            except WebSocketClosed as error:
                self.state.mark_disconnected(str(error))
                if error.code == 4011:
                    # The OBS protocol explicitly forbids automatic reconnect
                    # after SessionInvalidated. A process restart is required.
                    stop_event.wait()
                    return
            except Exception as error:
                self.state.mark_disconnected(
                    f"OBS WebSocket unavailable ({error.__class__.__name__}): {error}"
                )
            finally:
                session.close()
            if stop_event.wait(reconnect_delay):
                return
            reconnect_delay = min(
                self.maximum_reconnect_seconds, reconnect_delay * 2.0
            )


class HealthHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def server_bind(self) -> None:
        # HTTPServer normally performs a reverse-DNS lookup for server_name.
        # This listener is loopback-only and never uses that name; bypassing the
        # lookup avoids startup stalls when venue DNS is absent or unhealthy.
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def make_health_handler(
    state: EncoderHealthState,
) -> type[BaseHTTPRequestHandler]:
    class HealthHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:
            if self.path != "/health":
                self.send_error(404)
                return
            body = json.dumps(
                state.payload(), separators=(",", ":"), ensure_ascii=True
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format: str, *args: Any) -> None:
            pass

    return HealthHandler


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Expose authenticated OBS encoder health to AutoMix"
    )
    parser.add_argument(
        "--obs-host",
        default="127.0.0.1",
        help="OBS WebSocket loopback host (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--obs-port",
        type=int,
        default=4455,
        help="OBS WebSocket port (default: 4455)",
    )
    parser.add_argument(
        "--password-file",
        type=Path,
        help="owner-only file containing the OBS WebSocket password",
    )
    parser.add_argument(
        "--allow-unauthenticated",
        action="store_true",
        help="rehearsal only: allow OBS WebSocket authentication to be disabled",
    )
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument(
        "--audio-input-name",
        help="exact OBS program-audio input name whose carrier must be fresh",
    )
    selector.add_argument(
        "--audio-input-uuid",
        help="exact OBS program-audio input UUID whose carrier must be fresh",
    )
    parser.add_argument(
        "--listen-port",
        type=int,
        default=8421,
        help="loopback health HTTP port (default: 8421)",
    )
    parser.add_argument(
        "--audio-track",
        type=int,
        default=1,
        help="OBS streaming audio track that must include the input (default: 1)",
    )
    parser.add_argument(
        "--status-poll-ms",
        type=int,
        default=1000,
        help="GetStreamStatus interval in milliseconds (default: 1000)",
    )
    parser.add_argument(
        "--websocket-timeout-ms",
        type=int,
        default=2000,
        help="OBS WebSocket connect/request timeout (default: 2000)",
    )
    parser.add_argument(
        "--maximum-status-age-ms",
        type=int,
        default=3000,
        help="maximum accepted stream-status age (default: 3000)",
    )
    parser.add_argument(
        "--maximum-meter-age-ms",
        type=int,
        default=1000,
        help="maximum accepted audio-carrier meter age (default: 1000)",
    )
    parser.add_argument(
        "--check-config",
        action="store_true",
        help="validate configuration and private password file, then exit",
    )
    return parser


def validate_arguments(arguments: argparse.Namespace) -> None:
    validate_loopback_host(arguments.obs_host, "OBS WebSocket host")
    validate_port(arguments.obs_port, "OBS WebSocket port")
    validate_port(arguments.listen_port, "health HTTP port")
    require_range(
        float(arguments.status_poll_ms),
        250.0,
        5000.0,
        "OBS status poll interval",
    )
    require_range(
        float(arguments.websocket_timeout_ms),
        100.0,
        10000.0,
        "OBS WebSocket timeout",
    )
    require_range(
        float(arguments.maximum_status_age_ms),
        250.0,
        15000.0,
        "maximum stream-status age",
    )
    require_range(
        float(arguments.maximum_meter_age_ms),
        100.0,
        5000.0,
        "maximum OBS meter age",
    )
    AudioInputSelector(
        name=arguments.audio_input_name,
        uuid=arguments.audio_input_uuid,
    )
    if (
        isinstance(arguments.audio_track, bool)
        or arguments.audio_track < 1
        or arguments.audio_track > 6
    ):
        raise ConfigurationError("OBS audio track must be between 1 and 6")
    if not arguments.allow_unauthenticated and arguments.password_file is None:
        raise ConfigurationError(
            "--password-file is required for production monitoring"
        )
    if arguments.password_file is not None:
        read_private_secret(arguments.password_file)


def run_bridge(arguments: argparse.Namespace) -> int:
    validate_arguments(arguments)
    selector = AudioInputSelector(
        name=arguments.audio_input_name,
        uuid=arguments.audio_input_uuid,
    )
    state = EncoderHealthState(
        selector,
        audio_track=arguments.audio_track,
        maximum_status_age_ms=arguments.maximum_status_age_ms,
        maximum_meter_age_ms=arguments.maximum_meter_age_ms,
        production_eligible=not arguments.allow_unauthenticated,
    )

    def password_loader() -> Optional[str]:
        if arguments.password_file is None:
            return None
        return read_private_secret(arguments.password_file)

    def session_factory() -> OBSProtocolSession:
        return OBSProtocolSession(
            arguments.obs_host,
            arguments.obs_port,
            arguments.websocket_timeout_ms / 1000.0,
            password_loader,
            require_authentication=not arguments.allow_unauthenticated,
        )

    monitor = OBSMonitor(
        state,
        session_factory,
        poll_interval_seconds=arguments.status_poll_ms / 1000.0,
    )
    stop_event = threading.Event()
    monitor_thread = threading.Thread(
        target=monitor.run,
        args=(stop_event,),
        name="obs-health-monitor",
        daemon=True,
    )
    server = HealthHTTPServer(
        ("127.0.0.1", arguments.listen_port),
        make_health_handler(state),
    )

    def request_shutdown(_signal_number: int, _frame: Any) -> None:
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, request_shutdown)
    signal.signal(signal.SIGTERM, request_shutdown)
    monitor_thread.start()
    print(
        f"AutoMix OBS health: http://127.0.0.1:{server.server_port}/health "
        f"(OBS {arguments.obs_host}:{arguments.obs_port}, audio {selector.label})",
        flush=True,
    )
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        stop_event.set()
        server.server_close()
        monitor_thread.join(timeout=3.0)
    return 0


def main() -> int:
    parser = build_parser()
    arguments = parser.parse_args()
    try:
        if arguments.check_config:
            validate_arguments(arguments)
            print("AutoMix OBS health configuration OK")
            return 0
        return run_bridge(arguments)
    except ConfigurationError as error:
        print(f"configuration error: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"startup error: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
