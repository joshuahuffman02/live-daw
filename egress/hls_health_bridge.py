#!/usr/bin/env python3
"""Fail-closed public HLS playback observer for AutoMix.

The observer is designed to run on a machine and network separate from the
streaming Mac. It follows an HTTPS HLS master/media playlist, requires live media
sequence progress, downloads the newest published segment from the public CDN,
decodes one audio frame with FFmpeg, and exposes the AutoMix stream-health JSON
contract.

Only Python's standard library is used. FFmpeg is the sole runtime dependency.
The private playback URL is read from an owner-only file and is never placed in
process arguments, health JSON, or logs.
"""

from __future__ import annotations

import argparse
import http.client
import ipaddress
import json
import math
import os
import re
import shutil
import signal
import socket
import socketserver
import ssl
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple
from urllib.parse import SplitResult, urljoin, urlsplit


FORMAT_VERSION = 1
HEALTH_KIND = "automix-hls-egress-health"
MAX_URL_BYTES = 8 * 1024
MAX_PLAYLIST_BYTES = 1024 * 1024
MAX_MAP_BYTES = 8 * 1024 * 1024
MAX_SEGMENT_BYTES = 32 * 1024 * 1024
MAX_COMBINED_MEDIA_BYTES = 40 * 1024 * 1024
MAX_REDIRECTS = 4
MAX_SIGNED_TIMESTAMP_MS = (1 << 63) - 1
REDIRECT_STATUSES = {301, 302, 303, 307, 308}


def epoch_ms() -> int:
    return int(time.time() * 1000.0)


class ConfigurationError(ValueError):
    pass


class PlaybackError(RuntimeError):
    pass


class PlaylistError(PlaybackError):
    pass


class DecoderError(PlaybackError):
    pass


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


def _clean_identity(value: str, label: str, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise ConfigurationError(f"{label} is invalid")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ConfigurationError(f"{label} must not contain control characters")
    return value.strip()


def read_private_line(path: Path, label: str) -> str:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ConfigurationError(f"{label} path must be a regular file")
        if info.st_mode & 0o077:
            raise ConfigurationError(
                f"{label} file must not be group/world accessible"
            )
        if info.st_size <= 0 or info.st_size > MAX_URL_BYTES:
            raise ConfigurationError(f"{label} file size is invalid")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            raw = stream.read(MAX_URL_BYTES + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(raw) > MAX_URL_BYTES:
        raise ConfigurationError(f"{label} file is too large")
    try:
        value = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ConfigurationError(f"{label} file must contain UTF-8") from error
    if value.endswith("\n"):
        value = value[:-1]
        if value.endswith("\r"):
            value = value[:-1]
    if not value or "\x00" in value or "\r" in value or "\n" in value:
        raise ConfigurationError(
            f"{label} file must contain exactly one non-empty line"
        )
    return value


def validate_listen_host(value: str, allow_remote: bool) -> str:
    host = value.strip()
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        raise ConfigurationError(
            "health listen host must be a numeric IP address"
        ) from error
    if not address.is_loopback and not allow_remote:
        raise ConfigurationError(
            "non-loopback health binding requires --allow-remote-health"
        )
    return host


def _validate_url(
    value: str,
    *,
    allow_http: bool,
    allow_private: bool,
) -> SplitResult:
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > MAX_URL_BYTES
    ):
        raise ConfigurationError("playback URL is empty or too large")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ConfigurationError("playback URL contains control characters")
    try:
        value.encode("ascii")
    except UnicodeEncodeError as error:
        raise ConfigurationError(
            "playback URL must use ASCII/percent-encoded syntax"
        ) from error
    parsed = urlsplit(value)
    scheme = parsed.scheme.lower()
    if scheme != "https" and not (allow_http and scheme == "http"):
        raise ConfigurationError("production playback URLs must use HTTPS")
    if not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise ConfigurationError(
            "playback URL must have a host and must not contain credentials"
        )
    if parsed.fragment:
        raise ConfigurationError("playback URL must not contain a fragment")
    try:
        port = parsed.port
    except ValueError as error:
        raise ConfigurationError("playback URL port is invalid") from error
    if port is not None:
        validate_port(port, "playback URL port")
    try:
        literal = ipaddress.ip_address(parsed.hostname)
    except ValueError:
        literal = None
    if literal is not None and not allow_private and not literal.is_global:
        raise ConfigurationError(
            "production playback URL must not target a private/local address"
        )
    return parsed


@dataclass(frozen=True)
class HTTPResponse:
    url: str
    status: int
    headers: Dict[str, str]
    body: bytes


class SafeHTTPClient:
    """Small direct HTTP client with redirect and peer-address validation."""

    def __init__(
        self,
        *,
        timeout_seconds: float = 3.0,
        allow_http: bool = False,
        allow_private: bool = False,
        maximum_redirects: int = MAX_REDIRECTS,
    ) -> None:
        self.timeout_seconds = require_range(
            timeout_seconds, 0.25, 15.0, "playback HTTP timeout"
        )
        self.allow_http = allow_http
        self.allow_private = allow_private
        if maximum_redirects < 0 or maximum_redirects > 8:
            raise ConfigurationError("maximum redirects must be between 0 and 8")
        self.maximum_redirects = maximum_redirects
        self.tls_context = ssl.create_default_context()

    def validate_url(self, url: str) -> SplitResult:
        return _validate_url(
            url,
            allow_http=self.allow_http,
            allow_private=self.allow_private,
        )

    def _resolved_addresses(self, host: str, port: int) -> List[str]:
        try:
            records = socket.getaddrinfo(
                host,
                port,
                type=socket.SOCK_STREAM,
                proto=socket.IPPROTO_TCP,
            )
        except OSError as error:
            raise PlaybackError(f"playback DNS failed: {error}") from error
        addresses: List[str] = []
        for record in records:
            address = record[4][0]
            try:
                parsed = ipaddress.ip_address(address)
            except ValueError:
                continue
            if not self.allow_private and not parsed.is_global:
                continue
            if address not in addresses:
                addresses.append(address)
        if not addresses:
            raise PlaybackError(
                "playback host did not resolve to an allowed public address"
            )
        return addresses

    def _connection(
        self, parsed: SplitResult
    ) -> Tuple[http.client.HTTPConnection, str]:
        host = parsed.hostname
        if host is None:
            raise PlaybackError("playback host is missing")
        try:
            ascii_host = host.encode("idna").decode("ascii")
        except UnicodeError as error:
            raise PlaybackError("playback host is invalid") from error
        port = parsed.port or (443 if parsed.scheme.lower() == "https" else 80)
        last_error: Optional[BaseException] = None
        for address in self._resolved_addresses(ascii_host, port):
            raw: Optional[socket.socket] = None
            try:
                raw = socket.create_connection(
                    (address, port), timeout=self.timeout_seconds
                )
                peer = ipaddress.ip_address(raw.getpeername()[0])
                if not self.allow_private and not peer.is_global:
                    raise PlaybackError(
                        "playback connection reached a non-public peer"
                    )
                raw.settimeout(self.timeout_seconds)
                if parsed.scheme.lower() == "https":
                    connection: http.client.HTTPConnection = (
                        http.client.HTTPSConnection(
                            ascii_host,
                            port,
                            timeout=self.timeout_seconds,
                            context=self.tls_context,
                        )
                    )
                    connection.sock = self.tls_context.wrap_socket(
                        raw, server_hostname=ascii_host
                    )
                else:
                    connection = http.client.HTTPConnection(
                        ascii_host, port, timeout=self.timeout_seconds
                    )
                    connection.sock = raw
                return connection, address
            except (OSError, ssl.SSLError, PlaybackError) as error:
                last_error = error
                if raw is not None:
                    try:
                        raw.close()
                    except OSError:
                        pass
        raise PlaybackError(
            f"playback connection failed: {last_error or 'no usable address'}"
        )

    def fetch(
        self,
        url: str,
        *,
        maximum_bytes: int,
        accept: str,
        byte_range: Optional[Tuple[int, int]] = None,
    ) -> HTTPResponse:
        if maximum_bytes < 1:
            raise ConfigurationError("maximum HTTP response size is invalid")
        current = url
        for redirect_index in range(self.maximum_redirects + 1):
            parsed = self.validate_url(current)
            connection, _peer = self._connection(parsed)
            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query
            headers = {
                "Accept": accept,
                "Accept-Encoding": "identity",
                "Cache-Control": "no-cache",
                "Pragma": "no-cache",
                "User-Agent": "AutoMix-HLS-Egress/1",
            }
            expected_range: Optional[Tuple[int, int]] = None
            if byte_range is not None:
                start, length = byte_range
                if start < 0 or length < 1:
                    raise ConfigurationError("HTTP byte range is invalid")
                if length > maximum_bytes:
                    raise PlaybackError(
                        "requested playback byte range exceeds the configured limit"
                    )
                end = start + length - 1
                expected_range = (start, end)
                headers["Range"] = f"bytes={start}-{end}"
            try:
                connection.request("GET", path, headers=headers)
                response = connection.getresponse()
                response_headers = {
                    name.lower(): value.strip()
                    for name, value in response.getheaders()
                }
                status = response.status
                if status in REDIRECT_STATUSES:
                    response.read(1024)
                    location = response_headers.get("location", "")
                    if not location:
                        raise PlaybackError(
                            f"playback redirect HTTP {status} has no Location"
                        )
                    if redirect_index >= self.maximum_redirects:
                        raise PlaybackError("playback redirect limit exceeded")
                    current = urljoin(current, location)
                    self.validate_url(current)
                    continue
                expected_status = 206 if expected_range is not None else 200
                if status != expected_status:
                    raise PlaybackError(
                        f"playback HTTP {status}; expected {expected_status}"
                    )
                encoding = response_headers.get("content-encoding", "identity")
                if encoding.lower() not in ("", "identity"):
                    raise PlaybackError(
                        f"unsupported playback content encoding {encoding}"
                    )
                length_header = response_headers.get("content-length")
                declared_length: Optional[int] = None
                if length_header is not None:
                    if not length_header.isdigit():
                        raise PlaybackError(
                            "playback Content-Length is invalid"
                        )
                    declared_length = int(length_header)
                    if declared_length < 0 or declared_length > maximum_bytes:
                        raise PlaybackError(
                            "playback response exceeds the configured limit"
                        )
                if expected_range is not None:
                    start, end = expected_range
                    content_range = response_headers.get("content-range", "")
                    match = re.fullmatch(
                        r"bytes ([0-9]+)-([0-9]+)/([0-9]+|\*)",
                        content_range,
                        flags=re.IGNORECASE,
                    )
                    if (
                        match is None
                        or int(match.group(1)) != start
                        or int(match.group(2)) != end
                        or (
                            match.group(3) != "*"
                            and int(match.group(3)) <= end
                        )
                    ):
                        raise PlaybackError(
                            "playback byte-range response is inconsistent"
                        )
                    expected_length = end - start + 1
                    if (
                        declared_length is not None
                        and declared_length != expected_length
                    ):
                        raise PlaybackError(
                            "playback byte-range length is inconsistent"
                        )
                body = response.read(maximum_bytes + 1)
                if len(body) > maximum_bytes:
                    raise PlaybackError(
                        "playback response exceeds the configured limit"
                    )
                if (
                    declared_length is not None
                    and len(body) != declared_length
                ):
                    raise PlaybackError(
                        "playback response body is incomplete"
                    )
                if (
                    expected_range is not None
                    and len(body) != expected_range[1] - expected_range[0] + 1
                ):
                    raise PlaybackError(
                        "playback byte-range body is incomplete"
                    )
                return HTTPResponse(
                    url=current,
                    status=status,
                    headers=response_headers,
                    body=body,
                )
            except (OSError, http.client.HTTPException) as error:
                raise PlaybackError(f"playback HTTP failed: {error}") from error
            finally:
                connection.close()
        raise PlaybackError("playback redirect limit exceeded")


def parse_attribute_list(value: str) -> Dict[str, str]:
    attributes: Dict[str, str] = {}
    index = 0
    while index < len(value):
        equals = value.find("=", index)
        if equals < 0:
            raise PlaylistError("HLS attribute is missing '='")
        name = value[index:equals].strip()
        if not name or name in attributes:
            raise PlaylistError("HLS attribute name is empty or duplicated")
        index = equals + 1
        if index < len(value) and value[index] == '"':
            index += 1
            closing = value.find('"', index)
            if closing < 0:
                raise PlaylistError("HLS quoted attribute is unterminated")
            attribute_value = value[index:closing]
            index = closing + 1
            if index < len(value) and value[index] != ",":
                raise PlaylistError("HLS quoted attribute has trailing data")
        else:
            comma = value.find(",", index)
            if comma < 0:
                attribute_value = value[index:].strip()
                index = len(value)
            else:
                attribute_value = value[index:comma].strip()
                index = comma
        if not attribute_value:
            raise PlaylistError(f"HLS attribute {name} is empty")
        attributes[name] = attribute_value
        if index < len(value):
            if value[index] != ",":
                raise PlaylistError("HLS attribute separator is invalid")
            index += 1
            if index >= len(value):
                raise PlaylistError("HLS attribute list has a trailing comma")
    return attributes


def _positive_int(value: str, label: str, maximum: int = (1 << 63) - 1) -> int:
    if not value.isdigit():
        raise PlaylistError(f"{label} must be an integer")
    result = int(value)
    if result < 0 or result > maximum:
        raise PlaylistError(f"{label} is out of range")
    return result


def _byte_range(
    value: str, label: str
) -> Tuple[int, Optional[int]]:
    pieces = value.split("@", 1)
    length = _positive_int(pieces[0], f"{label} length", MAX_SEGMENT_BYTES)
    if length < 1:
        raise PlaylistError(f"{label} length must be positive")
    offset = (
        _positive_int(pieces[1], f"{label} offset")
        if len(pieces) == 2
        else None
    )
    return length, offset


@dataclass(frozen=True)
class MediaReference:
    url: str
    byte_range: Optional[Tuple[int, int]] = None

    @property
    def identity(self) -> str:
        if self.byte_range is None:
            return self.url
        return f"{self.url}#{self.byte_range[0]}+{self.byte_range[1]}"


@dataclass(frozen=True)
class SegmentReference:
    sequence: int
    duration: float
    media: MediaReference
    initialization: Optional[MediaReference]

    @property
    def identity(self) -> str:
        return f"{self.sequence}:{self.media.identity}"


@dataclass(frozen=True)
class MediaPlaylist:
    url: str
    target_duration: int
    media_sequence: int
    segments: Tuple[SegmentReference, ...]
    end_list: bool


@dataclass(frozen=True)
class Variant:
    bandwidth: int
    audio_group: Optional[str]
    uri: str


@dataclass(frozen=True)
class AudioRendition:
    group_id: str
    uri: str
    default: bool
    autoselect: bool


def _playlist_lines(body: bytes) -> List[str]:
    try:
        text = body.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise PlaylistError("HLS playlist must be UTF-8") from error
    if "\x00" in text:
        raise PlaylistError("HLS playlist contains NUL")
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines or lines[0] != "#EXTM3U":
        raise PlaylistError("HLS playlist is missing #EXTM3U")
    if len(lines) > 50_000:
        raise PlaylistError("HLS playlist has too many lines")
    return lines


def parse_master_playlist(body: bytes, base_url: str) -> Optional[str]:
    lines = _playlist_lines(body)
    variants: List[Variant] = []
    renditions: List[AudioRendition] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("#EXT-X-MEDIA:"):
            attributes = parse_attribute_list(line.split(":", 1)[1])
            if (
                attributes.get("TYPE") == "AUDIO"
                and "GROUP-ID" in attributes
                and "URI" in attributes
            ):
                renditions.append(
                    AudioRendition(
                        group_id=attributes["GROUP-ID"],
                        uri=urljoin(base_url, attributes["URI"]),
                        default=attributes.get("DEFAULT") == "YES",
                        autoselect=attributes.get("AUTOSELECT") == "YES",
                    )
                )
        elif line.startswith("#EXT-X-STREAM-INF:"):
            attributes = parse_attribute_list(line.split(":", 1)[1])
            bandwidth = _positive_int(
                attributes.get("BANDWIDTH", ""),
                "HLS variant BANDWIDTH",
            )
            if bandwidth < 1:
                raise PlaylistError("HLS variant BANDWIDTH must be positive")
            uri_index = index + 1
            if uri_index >= len(lines) or lines[uri_index].startswith("#"):
                raise PlaylistError("HLS variant has no URI")
            variants.append(
                Variant(
                    bandwidth=bandwidth,
                    audio_group=attributes.get("AUDIO"),
                    uri=urljoin(base_url, lines[uri_index]),
                )
            )
            index = uri_index
        index += 1

    if not variants:
        if not renditions:
            return None
        chosen_audio = sorted(
            renditions,
            key=lambda item: (
                not item.default,
                not item.autoselect,
                item.group_id,
                item.uri,
            ),
        )[0]
        return chosen_audio.uri

    variants_with_audio_group = [
        variant for variant in variants if variant.audio_group is not None
    ]
    chosen_pool = variants_with_audio_group or variants
    chosen = sorted(chosen_pool, key=lambda item: (item.bandwidth, item.uri))[0]
    if chosen.audio_group is not None:
        matches = [
            rendition
            for rendition in renditions
            if rendition.group_id == chosen.audio_group
        ]
        if matches:
            return sorted(
                matches,
                key=lambda item: (
                    not item.default,
                    not item.autoselect,
                    item.uri,
                ),
            )[0].uri
    return chosen.uri


def parse_media_playlist(body: bytes, base_url: str) -> MediaPlaylist:
    lines = _playlist_lines(body)
    target_duration: Optional[int] = None
    playlist_type: Optional[str] = None
    media_sequence = 0
    skipped_segments = 0
    end_list = False
    pending_duration: Optional[float] = None
    pending_range: Optional[Tuple[int, Optional[int]]] = None
    current_map: Optional[MediaReference] = None
    previous_segment_url: Optional[str] = None
    previous_segment_end: Optional[int] = None
    segments: List[SegmentReference] = []

    for line in lines[1:]:
        if line.startswith("#EXT-X-TARGETDURATION:"):
            if target_duration is not None:
                raise PlaylistError("HLS target duration is duplicated")
            target_duration = _positive_int(
                line.split(":", 1)[1], "HLS target duration", 3600
            )
            if target_duration < 1:
                raise PlaylistError("HLS target duration must be positive")
        elif line.startswith("#EXT-X-PLAYLIST-TYPE:"):
            if playlist_type is not None:
                raise PlaylistError("HLS playlist type is duplicated")
            playlist_type = line.split(":", 1)[1]
            if playlist_type not in ("EVENT", "VOD"):
                raise PlaylistError("HLS playlist type is invalid")
            if playlist_type == "VOD":
                raise PlaylistError(
                    "HLS VOD playlist is finite, not a live public stream"
                )
        elif line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
            media_sequence = _positive_int(
                line.split(":", 1)[1], "HLS media sequence"
            )
        elif line.startswith("#EXT-X-SKIP:"):
            attributes = parse_attribute_list(line.split(":", 1)[1])
            skipped_segments = _positive_int(
                attributes.get("SKIPPED-SEGMENTS", ""),
                "HLS skipped segment count",
            )
        elif line.startswith("#EXT-X-KEY:"):
            attributes = parse_attribute_list(line.split(":", 1)[1])
            if attributes.get("METHOD") != "NONE":
                raise PlaylistError(
                    "encrypted HLS segments are not supported by this observer"
                )
        elif line.startswith("#EXT-X-MAP:"):
            attributes = parse_attribute_list(line.split(":", 1)[1])
            uri = attributes.get("URI")
            if not uri:
                raise PlaylistError("HLS initialization map has no URI")
            map_range: Optional[Tuple[int, int]] = None
            if "BYTERANGE" in attributes:
                length, offset = _byte_range(
                    attributes["BYTERANGE"], "HLS map byte range"
                )
                if offset is None:
                    raise PlaylistError(
                        "HLS map byte range must have an explicit offset"
                    )
                map_range = (offset, length)
            current_map = MediaReference(
                url=urljoin(base_url, uri),
                byte_range=map_range,
            )
        elif line.startswith("#EXT-X-BYTERANGE:"):
            pending_range = _byte_range(
                line.split(":", 1)[1], "HLS segment byte range"
            )
        elif line.startswith("#EXTINF:"):
            raw_duration = line.split(":", 1)[1].split(",", 1)[0]
            try:
                duration = float(raw_duration)
            except ValueError as error:
                raise PlaylistError("HLS segment duration is invalid") from error
            if not math.isfinite(duration) or duration <= 0.0 or duration > 3600.0:
                raise PlaylistError("HLS segment duration is out of range")
            pending_duration = duration
        elif line == "#EXT-X-ENDLIST":
            end_list = True
        elif line.startswith("#"):
            continue
        else:
            if pending_duration is None:
                raise PlaylistError("HLS segment URI has no EXTINF")
            segment_url = urljoin(base_url, line)
            resolved_range: Optional[Tuple[int, int]] = None
            if pending_range is not None:
                length, offset = pending_range
                if offset is None:
                    if (
                        previous_segment_url != segment_url
                        or previous_segment_end is None
                    ):
                        raise PlaylistError(
                            "implicit HLS byte range has no matching predecessor"
                        )
                    offset = previous_segment_end
                resolved_range = (offset, length)
                previous_segment_url = segment_url
                previous_segment_end = offset + length
            else:
                previous_segment_url = None
                previous_segment_end = None
            sequence = media_sequence + skipped_segments + len(segments)
            if sequence > MAX_SIGNED_TIMESTAMP_MS:
                raise PlaylistError("HLS media sequence is out of range")
            segments.append(
                SegmentReference(
                    sequence=sequence,
                    duration=pending_duration,
                    media=MediaReference(segment_url, resolved_range),
                    initialization=current_map,
                )
            )
            if len(segments) > 10_000:
                raise PlaylistError("HLS playlist contains too many segments")
            pending_duration = None
            pending_range = None

    if pending_duration is not None or pending_range is not None:
        raise PlaylistError("HLS playlist ends with an incomplete segment")
    if target_duration is None:
        raise PlaylistError("HLS media playlist has no target duration")
    if not segments:
        raise PlaylistError("HLS media playlist has no complete segments")
    return MediaPlaylist(
        url=base_url,
        target_duration=target_duration,
        media_sequence=media_sequence,
        segments=tuple(segments),
        end_list=end_list,
    )


class PlaylistResolver:
    def __init__(self, client: SafeHTTPClient, maximum_depth: int = 3) -> None:
        self.client = client
        if maximum_depth < 1 or maximum_depth > 5:
            raise ConfigurationError("playlist depth must be between 1 and 5")
        self.maximum_depth = maximum_depth

    def resolve(self, root_url: str) -> MediaPlaylist:
        current = root_url
        seen: set[str] = set()
        for _depth in range(self.maximum_depth):
            if current in seen:
                raise PlaylistError("HLS playlist recursion loop detected")
            seen.add(current)
            response = self.client.fetch(
                current,
                maximum_bytes=MAX_PLAYLIST_BYTES,
                accept=(
                    "application/vnd.apple.mpegurl, "
                    "application/x-mpegURL, audio/mpegurl, text/plain"
                ),
            )
            next_url = parse_master_playlist(response.body, response.url)
            if next_url is None:
                playlist = parse_media_playlist(response.body, response.url)
                if playlist.end_list:
                    raise PlaylistError(
                        "HLS playlist is finite/ended, not a live public stream"
                    )
                return playlist
            current = next_url
        raise PlaylistError("HLS playlist nesting exceeds the supported depth")


class FFmpegAudioDecoder:
    def __init__(
        self,
        executable: str,
        *,
        timeout_seconds: float = 5.0,
    ) -> None:
        requested = Path(executable).expanduser()
        if not requested.is_absolute():
            raise ConfigurationError("FFmpeg path must be absolute")
        try:
            resolved = requested.resolve(strict=True)
        except OSError as error:
            raise ConfigurationError(f"FFmpeg path is unavailable: {error}") from error
        if not resolved.is_file() or not os.access(resolved, os.X_OK):
            raise ConfigurationError("FFmpeg path must be an executable file")
        self.executable = str(resolved)
        self.timeout_seconds = require_range(
            timeout_seconds, 0.5, 15.0, "FFmpeg decode timeout"
        )
        try:
            version = subprocess.run(
                [self.executable, "-version"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=3.0,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ConfigurationError(f"FFmpeg version check failed: {error}") from error
        first_line = version.stdout.decode("utf-8", "replace").splitlines()
        if version.returncode != 0 or not first_line or not first_line[0].startswith(
            "ffmpeg version "
        ):
            raise ConfigurationError("configured executable is not FFmpeg")
        self.version = first_line[0][:256]

    def decode_one_audio_frame(
        self, initialization: bytes, segment: bytes
    ) -> int:
        media = initialization + segment
        if not media or len(media) > MAX_COMBINED_MEDIA_BYTES:
            raise DecoderError("HLS media payload is empty or too large")
        command = [
            self.executable,
            "-v",
            "error",
            "-nostdin",
            "-probesize",
            "8M",
            "-analyzeduration",
            "5000000",
            "-i",
            "pipe:0",
            "-map",
            "0:a:0",
            "-frames:a",
            "1",
            "-f",
            "f32le",
            "-acodec",
            "pcm_f32le",
            "pipe:1",
        ]
        try:
            result = subprocess.run(
                command,
                input=media,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.timeout_seconds,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise DecoderError("FFmpeg audio decode timed out") from error
        except OSError as error:
            raise DecoderError(f"FFmpeg audio decode failed: {error}") from error
        decoded = result.stdout
        if result.returncode != 0 or len(decoded) < 4 or len(decoded) % 4 != 0:
            detail = result.stderr.decode("utf-8", "replace")
            detail = " ".join(detail.split())[:256]
            suffix = f": {detail}" if detail else ""
            raise DecoderError(
                f"newest HLS segment has no decodable audio frame{suffix}"
            )
        if len(decoded) > 1024 * 1024:
            raise DecoderError("FFmpeg produced an unexpectedly large audio frame")
        return len(decoded) // 4


@dataclass(frozen=True)
class SegmentCursor:
    sequence: int
    identity: str


class EgressHealthState:
    def __init__(
        self,
        observer_site: str,
        ffmpeg_version: str,
        *,
        production_eligible: bool,
        maximum_progress_age_ms: int = 15_000,
    ) -> None:
        self.observer_site = _clean_identity(observer_site, "observer site")
        self.ffmpeg_version = ffmpeg_version
        self.production_eligible = production_eligible
        self.maximum_progress_age_ms = int(
            require_range(
                float(maximum_progress_age_ms),
                2_000.0,
                15_000.0,
                "maximum HLS progress age",
            )
        )
        self._lock = threading.Lock()
        self.cursor: Optional[SegmentCursor] = None
        self.last_progress_ms = 0
        self.last_observation_ms = epoch_ms()
        self.audio_samples = 0
        self.playback_host = ""
        self.target_duration_seconds = 0
        self.failure = "waiting for initial public HLS observation"
        self.baseline_ready = False
        self.poll_generation = 0

    @staticmethod
    def _host(url: str) -> str:
        return urlsplit(url).hostname or ""

    def mark_failure(self, reason: str) -> None:
        clean = " ".join(str(reason).split())[:512] or "public playback unavailable"
        with self._lock:
            self.failure = clean
            self.last_observation_ms = epoch_ms()
            self.poll_generation += 1

    def observe_baseline(
        self,
        cursor: SegmentCursor,
        decoded_samples: int,
        playlist_url: str,
        target_duration_seconds: int,
        *,
        reset: bool = False,
    ) -> None:
        timestamp = epoch_ms()
        with self._lock:
            self.cursor = cursor
            self.audio_samples = decoded_samples
            self.playback_host = self._host(playlist_url)
            self.target_duration_seconds = target_duration_seconds
            self.last_progress_ms = 0
            self.last_observation_ms = timestamp
            self.baseline_ready = True
            self.failure = (
                "HLS sequence reset; waiting for renewed public progression"
                if reset
                else "public audio carrier decoded; waiting for HLS progression"
            )
            self.poll_generation += 1

    def observe_progress(
        self,
        cursor: SegmentCursor,
        decoded_samples: int,
        playlist_url: str,
        target_duration_seconds: int,
    ) -> None:
        timestamp = epoch_ms()
        with self._lock:
            self.cursor = cursor
            self.audio_samples = decoded_samples
            self.playback_host = self._host(playlist_url)
            self.target_duration_seconds = target_duration_seconds
            self.last_progress_ms = timestamp
            self.last_observation_ms = timestamp
            self.baseline_ready = True
            self.failure = ""
            self.poll_generation += 1

    def note_playlist_success(
        self, playlist_url: str, target_duration_seconds: int
    ) -> None:
        timestamp = epoch_ms()
        with self._lock:
            self.playback_host = self._host(playlist_url)
            self.target_duration_seconds = target_duration_seconds
            if self.last_progress_ms > 0:
                self.failure = ""
            self.last_observation_ms = timestamp
            self.poll_generation += 1

    def payload(self, now_ms: Optional[int] = None) -> Dict[str, Any]:
        now = epoch_ms() if now_ms is None else now_ms
        with self._lock:
            cursor = self.cursor
            last_progress_ms = self.last_progress_ms
            last_observation_ms = self.last_observation_ms
            audio_samples = self.audio_samples
            playback_host = self.playback_host
            target_duration_seconds = self.target_duration_seconds
            failure = self.failure
            baseline_ready = self.baseline_ready
            poll_generation = self.poll_generation

        progress_age_ms = (
            now - last_progress_ms if last_progress_ms > 0 else None
        )
        progress_fresh = bool(
            progress_age_ms is not None
            and -5_000 <= progress_age_ms <= self.maximum_progress_age_ms
        )
        streaming = bool(not failure and progress_fresh and cursor is not None)
        audio_active = bool(
            not failure
            and progress_fresh
            and cursor is not None
            and audio_samples > 0
        )
        healthy = bool(
            self.production_eligible
            and not failure
            and streaming
            and audio_active
        )

        if not self.production_eligible:
            detail = (
                "rehearsal/private playback override cannot produce production health"
            )
        elif failure:
            detail = failure
        elif not baseline_ready:
            detail = "waiting for initial public HLS observation"
        elif last_progress_ms <= 0:
            detail = "waiting for public HLS sequence progression"
        elif not progress_fresh:
            detail = "public HLS media sequence is stale"
        else:
            detail = (
                f"public HLS advancing via {playback_host}; "
                f"sequence {cursor.sequence if cursor else 'unknown'}; "
                f"decoded {audio_samples} audio samples"
            )

        if last_progress_ms > 0:
            observation_timestamp = last_progress_ms
        else:
            observation_timestamp = last_observation_ms
        observation_timestamp = max(
            1, min(MAX_SIGNED_TIMESTAMP_MS, observation_timestamp)
        )

        return {
            "formatVersion": FORMAT_VERSION,
            "kind": HEALTH_KIND,
            "healthy": healthy,
            "streaming": streaming,
            "audioActive": audio_active,
            "timestampMs": observation_timestamp,
            "detail": detail,
            "observerSite": self.observer_site,
            "productionEligible": self.production_eligible,
            "playbackHost": playback_host,
            "mediaSequence": cursor.sequence if cursor is not None else None,
            "progressAgeMs": progress_age_ms,
            "targetDurationSeconds": target_duration_seconds,
            "decodedAudioSamples": audio_samples,
            "ffmpegVersion": self.ffmpeg_version,
            "pollGeneration": poll_generation,
        }


class HLSMonitor:
    def __init__(
        self,
        root_url: str,
        resolver: PlaylistResolver,
        client: SafeHTTPClient,
        decoder: FFmpegAudioDecoder,
        state: EgressHealthState,
        *,
        poll_interval_seconds: float = 2.0,
    ) -> None:
        self.root_url = root_url
        self.resolver = resolver
        self.client = client
        self.decoder = decoder
        self.state = state
        self.poll_interval_seconds = require_range(
            poll_interval_seconds, 0.5, 10.0, "HLS poll interval"
        )
        self.last_cursor: Optional[SegmentCursor] = None
        self.cached_map_identity = ""
        self.cached_map = b""

    def _fetch_reference(
        self, reference: MediaReference, maximum_bytes: int
    ) -> bytes:
        response = self.client.fetch(
            reference.url,
            maximum_bytes=maximum_bytes,
            accept="application/octet-stream, video/mp2t, audio/aac, audio/mp4, video/mp4",
            byte_range=reference.byte_range,
        )
        if not response.body:
            raise PlaybackError("public HLS media response is empty")
        return response.body

    def _decode_segment(self, segment: SegmentReference) -> int:
        initialization = b""
        if segment.initialization is not None:
            identity = segment.initialization.identity
            if identity != self.cached_map_identity:
                self.cached_map = self._fetch_reference(
                    segment.initialization, MAX_MAP_BYTES
                )
                self.cached_map_identity = identity
            initialization = self.cached_map
        media = self._fetch_reference(segment.media, MAX_SEGMENT_BYTES)
        return self.decoder.decode_one_audio_frame(initialization, media)

    def poll_once(self) -> None:
        playlist = self.resolver.resolve(self.root_url)
        latest = playlist.segments[-1]
        cursor = SegmentCursor(latest.sequence, latest.identity)
        previous = self.last_cursor

        if previous is None:
            decoded = self._decode_segment(latest)
            self.last_cursor = cursor
            self.state.observe_baseline(
                cursor,
                decoded,
                playlist.url,
                playlist.target_duration,
            )
            return

        if (
            cursor.sequence < previous.sequence
            or (
                cursor.sequence == previous.sequence
                and cursor.identity != previous.identity
            )
        ):
            decoded = self._decode_segment(latest)
            self.last_cursor = cursor
            self.state.observe_baseline(
                cursor,
                decoded,
                playlist.url,
                playlist.target_duration,
                reset=True,
            )
            return

        if cursor.sequence == previous.sequence:
            self.state.note_playlist_success(
                playlist.url, playlist.target_duration
            )
            return

        decoded = self._decode_segment(latest)
        self.last_cursor = cursor
        self.state.observe_progress(
            cursor,
            decoded,
            playlist.url,
            playlist.target_duration,
        )

    def run(self, stop_event: threading.Event) -> None:
        while not stop_event.is_set():
            started = time.monotonic()
            try:
                self.poll_once()
            except Exception as error:
                self.state.mark_failure(
                    f"public HLS unavailable ({error.__class__.__name__}): {error}"
                )
            elapsed = time.monotonic() - started
            wait = max(0.05, self.poll_interval_seconds - elapsed)
            if stop_event.wait(wait):
                return


class EgressHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class IPv6EgressHTTPServer(EgressHTTPServer):
    address_family = socket.AF_INET6


def make_health_handler(
    state: EgressHealthState,
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


def _default_ffmpeg() -> str:
    discovered = shutil.which("ffmpeg")
    return discovered or ""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Expose independently observed public HLS health to AutoMix"
    )
    parser.add_argument(
        "--playlist-url-file",
        required=True,
        type=Path,
        help="owner-only file containing the public HLS master/media URL",
    )
    parser.add_argument(
        "--observer-site",
        required=True,
        help="stable label for the independent observer location/network",
    )
    parser.add_argument(
        "--ffmpeg",
        default=_default_ffmpeg(),
        help="absolute FFmpeg executable path",
    )
    parser.add_argument(
        "--listen-host",
        default="127.0.0.1",
        help="numeric health bind address (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--listen-port",
        type=int,
        default=8422,
        help="health HTTP port (default: 8422)",
    )
    parser.add_argument(
        "--allow-remote-health",
        action="store_true",
        help="allow health binding beyond loopback; protect it with VPN/firewall ACLs",
    )
    parser.add_argument(
        "--poll-ms",
        type=int,
        default=2000,
        help="HLS playlist poll interval in milliseconds (default: 2000)",
    )
    parser.add_argument(
        "--http-timeout-ms",
        type=int,
        default=3000,
        help="per-resource public HTTP timeout (default: 3000)",
    )
    parser.add_argument(
        "--maximum-progress-age-ms",
        type=int,
        default=15000,
        help="maximum accepted time since a new segment (default: 15000)",
    )
    parser.add_argument(
        "--allow-rehearsal-http-private-playback",
        action="store_true",
        help="tests/rehearsal only; resulting health is never production-eligible",
    )
    parser.add_argument(
        "--check-config",
        action="store_true",
        help="validate private URL, network policy, FFmpeg, and listener settings",
    )
    return parser


@dataclass(frozen=True)
class ValidatedConfiguration:
    root_url: str
    observer_site: str
    ffmpeg: FFmpegAudioDecoder
    listen_host: str
    production_eligible: bool


def validate_arguments(arguments: argparse.Namespace) -> ValidatedConfiguration:
    root_url = read_private_line(arguments.playlist_url_file, "HLS playback URL")
    rehearsal = bool(arguments.allow_rehearsal_http_private_playback)
    _validate_url(
        root_url,
        allow_http=rehearsal,
        allow_private=rehearsal,
    )
    observer_site = _clean_identity(arguments.observer_site, "observer site")
    if not arguments.ffmpeg:
        raise ConfigurationError(
            "FFmpeg was not found; configure an absolute --ffmpeg path"
        )
    decoder = FFmpegAudioDecoder(arguments.ffmpeg)
    listen_host = validate_listen_host(
        arguments.listen_host, bool(arguments.allow_remote_health)
    )
    validate_port(arguments.listen_port, "health HTTP port")
    require_range(
        float(arguments.poll_ms),
        500.0,
        10_000.0,
        "HLS poll interval",
    )
    require_range(
        float(arguments.http_timeout_ms),
        250.0,
        15_000.0,
        "playback HTTP timeout",
    )
    require_range(
        float(arguments.maximum_progress_age_ms),
        2_000.0,
        15_000.0,
        "maximum HLS progress age",
    )
    return ValidatedConfiguration(
        root_url=root_url,
        observer_site=observer_site,
        ffmpeg=decoder,
        listen_host=listen_host,
        production_eligible=not rehearsal,
    )


def run_bridge(arguments: argparse.Namespace) -> int:
    configuration = validate_arguments(arguments)
    client = SafeHTTPClient(
        timeout_seconds=arguments.http_timeout_ms / 1000.0,
        allow_http=not configuration.production_eligible,
        allow_private=not configuration.production_eligible,
    )
    resolver = PlaylistResolver(client)
    state = EgressHealthState(
        configuration.observer_site,
        configuration.ffmpeg.version,
        production_eligible=configuration.production_eligible,
        maximum_progress_age_ms=arguments.maximum_progress_age_ms,
    )
    monitor = HLSMonitor(
        configuration.root_url,
        resolver,
        client,
        configuration.ffmpeg,
        state,
        poll_interval_seconds=arguments.poll_ms / 1000.0,
    )
    stop_event = threading.Event()
    monitor_thread = threading.Thread(
        target=monitor.run,
        args=(stop_event,),
        name="hls-egress-monitor",
        daemon=True,
    )
    server_type = (
        IPv6EgressHTTPServer
        if ":" in configuration.listen_host
        else EgressHTTPServer
    )
    server = server_type(
        (configuration.listen_host, arguments.listen_port),
        make_health_handler(state),
    )

    def request_shutdown(_signal_number: int, _frame: Any) -> None:
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, request_shutdown)
    signal.signal(signal.SIGTERM, request_shutdown)
    monitor_thread.start()
    display_host = (
        f"[{configuration.listen_host}]"
        if ":" in configuration.listen_host
        else configuration.listen_host
    )
    print(
        f"AutoMix public HLS health: "
        f"http://{display_host}:{server.server_port}/health "
        f"(observer {configuration.observer_site})",
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
            configuration = validate_arguments(arguments)
            eligibility = (
                "production-eligible"
                if configuration.production_eligible
                else "rehearsal-only"
            )
            print(
                f"AutoMix HLS egress configuration OK ({eligibility}; "
                f"{configuration.ffmpeg.version})"
            )
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
