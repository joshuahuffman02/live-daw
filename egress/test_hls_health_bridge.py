#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, Dict, List, Optional
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))

from hls_health_bridge import (  # noqa: E402
    ConfigurationError,
    DecoderError,
    EgressHTTPServer,
    EgressHealthState,
    FFmpegAudioDecoder,
    FORMAT_VERSION,
    HEALTH_KIND,
    HLSMonitor,
    MediaPlaylist,
    MediaReference,
    PlaylistError,
    PlaylistResolver,
    PlaybackError,
    SafeHTTPClient,
    SegmentCursor,
    SegmentReference,
    _validate_url,
    make_health_handler,
    parse_attribute_list,
    parse_master_playlist,
    parse_media_playlist,
    read_private_line,
    validate_listen_host,
)


class MutableHLSServer:
    def __init__(self) -> None:
        self.media_sequence = 10
        self.segment_requests: List[str] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _send(
                self,
                status: int,
                body: bytes,
                content_type: str,
                extra: Optional[Dict[str, str]] = None,
            ) -> None:
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                if extra:
                    for name, value in extra.items():
                        self.send_header(name, value)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                if self.path == "/redirect":
                    self._send(
                        302,
                        b"",
                        "text/plain",
                        {"Location": "/master.m3u8"},
                    )
                    return
                if self.path == "/master.m3u8":
                    body = (
                        "#EXTM3U\n"
                        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",'
                        'NAME="Program",DEFAULT=YES,AUTOSELECT=YES,'
                        'URI="/audio.m3u8"\n'
                        '#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO="main"\n'
                        "/video.m3u8\n"
                    ).encode("utf-8")
                    self._send(
                        200, body, "application/vnd.apple.mpegurl"
                    )
                    return
                if self.path == "/audio.m3u8":
                    first = owner.media_sequence
                    body = (
                        "#EXTM3U\n"
                        "#EXT-X-TARGETDURATION:2\n"
                        f"#EXT-X-MEDIA-SEQUENCE:{first}\n"
                        "#EXTINF:2.0,\n"
                        f"/audio-{first}.aac\n"
                        "#EXTINF:2.0,\n"
                        f"/audio-{first + 1}.aac\n"
                        "#EXTINF:2.0,\n"
                        f"/audio-{first + 2}.aac\n"
                    ).encode("utf-8")
                    self._send(
                        200, body, "application/vnd.apple.mpegurl"
                    )
                    return
                if self.path.startswith("/audio-") and self.path.endswith(
                    ".aac"
                ):
                    owner.segment_requests.append(self.path)
                    self._send(
                        200,
                        b"decodable-public-audio-" + self.path.encode("ascii"),
                        "audio/aac",
                    )
                    return
                if self.path == "/range.bin":
                    full = b"0123456789"
                    requested = self.headers.get("Range")
                    if requested == "bytes=2-5":
                        self._send(
                            206,
                            full[2:6],
                            "application/octet-stream",
                            {"Content-Range": "bytes 2-5/10"},
                        )
                    else:
                        self._send(200, full, "application/octet-stream")
                    return
                if self.path == "/short-range.bin":
                    self._send(
                        206,
                        b"234",
                        "application/octet-stream",
                        {"Content-Range": "bytes 2-5/10"},
                    )
                    return
                if self.path == "/short.bin":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", "5")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(b"234")
                    return
                self._send(404, b"missing", "text/plain")

            def log_message(self, _format: str, *args: Any) -> None:
                pass

        self.server = EgressHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=self.server.serve_forever, daemon=True
        )
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def __enter__(self) -> "MutableHLSServer":
        self.thread.start()
        return self

    def __exit__(self, *args: Any) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2.0)


class FakeDecoder:
    version = "ffmpeg version deterministic-test"

    def __init__(self, samples: int = 1024) -> None:
        self.samples = samples
        self.calls: List[bytes] = []

    def decode_one_audio_frame(
        self, initialization: bytes, segment: bytes
    ) -> int:
        self.calls.append(initialization + segment)
        if self.samples <= 0:
            raise DecoderError("no audio")
        return self.samples


class ConfigurationTests(unittest.TestCase):
    def test_production_url_policy_rejects_unsafe_targets(self) -> None:
        self.assertEqual(
            _validate_url(
                "https://cdn.example.test/live/master.m3u8",
                allow_http=False,
                allow_private=False,
            ).scheme,
            "https",
        )
        bad = (
            "http://cdn.example.test/live.m3u8",
            "https://user:pass@cdn.example.test/live.m3u8",
            "https://cdn.example.test/live.m3u8#fragment",
            "https://127.0.0.1/live.m3u8",
            "file:///tmp/live.m3u8",
        )
        for value in bad:
            with self.subTest(value=value), self.assertRaises(ConfigurationError):
                _validate_url(
                    value, allow_http=False, allow_private=False
                )

    def test_rehearsal_policy_allows_loopback_http(self) -> None:
        parsed = _validate_url(
            "http://127.0.0.1:8080/live.m3u8",
            allow_http=True,
            allow_private=True,
        )
        self.assertEqual(parsed.hostname, "127.0.0.1")

    def test_production_client_rejects_dns_that_resolves_only_private(
        self,
    ) -> None:
        client = SafeHTTPClient()
        with mock.patch(
            "socket.getaddrinfo",
            return_value=[
                (
                    socket.AF_INET,
                    socket.SOCK_STREAM,
                    socket.IPPROTO_TCP,
                    "",
                    ("127.0.0.1", 443),
                )
            ],
        ), self.assertRaisesRegex(PlaybackError, "public address"):
            client._resolved_addresses("cdn.example.test", 443)

    def test_private_url_file_rejects_permissions_symlink_and_multiline(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            secret = root / "url"
            secret.write_text(
                "https://cdn.example.test/live.m3u8?private=value\n",
                encoding="utf-8",
            )
            os.chmod(secret, 0o600)
            self.assertEqual(
                read_private_line(secret, "URL"),
                "https://cdn.example.test/live.m3u8?private=value",
            )
            os.chmod(secret, 0o640)
            with self.assertRaises(ConfigurationError):
                read_private_line(secret, "URL")
            os.chmod(secret, 0o600)
            link = root / "link"
            link.symlink_to(secret)
            with self.assertRaises(OSError):
                read_private_line(link, "URL")
            secret.write_text("one\ntwo\n", encoding="utf-8")
            with self.assertRaises(ConfigurationError):
                read_private_line(secret, "URL")

    def test_non_loopback_health_bind_requires_explicit_authority(self) -> None:
        self.assertEqual(
            validate_listen_host("127.0.0.1", False), "127.0.0.1"
        )
        with self.assertRaises(ConfigurationError):
            validate_listen_host("0.0.0.0", False)
        self.assertEqual(validate_listen_host("0.0.0.0", True), "0.0.0.0")
        with self.assertRaises(ConfigurationError):
            validate_listen_host("observer.local", True)


class PlaylistParsingTests(unittest.TestCase):
    def test_attribute_parser_preserves_quoted_commas_and_rejects_duplicates(
        self,
    ) -> None:
        parsed = parse_attribute_list(
            'TYPE=AUDIO,GROUP-ID="program,main",DEFAULT=YES'
        )
        self.assertEqual(parsed["GROUP-ID"], "program,main")
        with self.assertRaises(PlaylistError):
            parse_attribute_list("TYPE=AUDIO,TYPE=VIDEO")
        with self.assertRaises(PlaylistError):
            parse_attribute_list('TYPE="AUDIO')

    def test_master_prefers_default_audio_rendition_for_lowest_variant(
        self,
    ) -> None:
        body = (
            "#EXTM3U\n"
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Alt",'
            'AUTOSELECT=YES,URI="alt.m3u8"\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Program",'
            'DEFAULT=YES,AUTOSELECT=YES,URI="program.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="main"\n'
            "high.m3u8\n"
            '#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO="main"\n'
            "low.m3u8\n"
        ).encode("utf-8")
        selected = parse_master_playlist(
            body, "https://cdn.example.test/root/master.m3u8"
        )
        self.assertEqual(
            selected, "https://cdn.example.test/root/program.m3u8"
        )

    def test_master_uses_lowest_muxed_variant(self) -> None:
        body = (
            "#EXTM3U\n"
            "#EXT-X-STREAM-INF:BANDWIDTH=900000\n"
            "high.m3u8\n"
            "#EXT-X-STREAM-INF:BANDWIDTH=200000\n"
            "low.m3u8\n"
        ).encode("utf-8")
        self.assertEqual(
            parse_master_playlist(
                body, "https://cdn.example.test/master.m3u8"
            ),
            "https://cdn.example.test/low.m3u8",
        )

    def test_master_prefers_audio_group_over_lower_video_only_variant(
        self,
    ) -> None:
        body = (
            "#EXTM3U\n"
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="Program",'
            'DEFAULT=YES,URI="program.m3u8"\n'
            "#EXT-X-STREAM-INF:BANDWIDTH=100000\n"
            "video-only.m3u8\n"
            '#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO="main"\n'
            "av.m3u8\n"
        ).encode("utf-8")
        self.assertEqual(
            parse_master_playlist(
                body, "https://cdn.example.test/master.m3u8"
            ),
            "https://cdn.example.test/program.m3u8",
        )

    def test_media_playlist_tracks_sequence_map_and_byte_ranges(self) -> None:
        body = (
            "#EXTM3U\n"
            "#EXT-X-TARGETDURATION:2\n"
            "#EXT-X-MEDIA-SEQUENCE:100\n"
            "#EXT-X-SKIP:SKIPPED-SEGMENTS=2\n"
            '#EXT-X-MAP:URI="media.mp4",BYTERANGE="100@0"\n'
            "#EXTINF:2.0,\n"
            "#EXT-X-BYTERANGE:400@100\n"
            "media.mp4\n"
            "#EXTINF:2.0,\n"
            "#EXT-X-BYTERANGE:300\n"
            "media.mp4\n"
        ).encode("utf-8")
        playlist = parse_media_playlist(
            body, "https://cdn.example.test/live/audio.m3u8"
        )
        self.assertEqual([item.sequence for item in playlist.segments], [102, 103])
        self.assertEqual(
            playlist.segments[0].initialization,
            MediaReference(
                "https://cdn.example.test/live/media.mp4", (0, 100)
            ),
        )
        self.assertEqual(playlist.segments[0].media.byte_range, (100, 400))
        self.assertEqual(playlist.segments[1].media.byte_range, (500, 300))

    def test_media_playlist_rejects_encryption_and_incomplete_ranges(self) -> None:
        encrypted = (
            "#EXTM3U\n"
            "#EXT-X-TARGETDURATION:2\n"
            '#EXT-X-KEY:METHOD=AES-128,URI="key"\n'
            "#EXTINF:2,\n"
            "segment.ts\n"
        ).encode("utf-8")
        with self.assertRaisesRegex(PlaylistError, "encrypted"):
            parse_media_playlist(
                encrypted, "https://cdn.example.test/live.m3u8"
            )

        implicit = (
            "#EXTM3U\n"
            "#EXT-X-TARGETDURATION:2\n"
            "#EXTINF:2,\n"
            "#EXT-X-BYTERANGE:100\n"
            "segment.ts\n"
        ).encode("utf-8")
        with self.assertRaisesRegex(PlaylistError, "predecessor"):
            parse_media_playlist(
                implicit, "https://cdn.example.test/live.m3u8"
            )

    def test_media_playlist_marks_or_rejects_finite_content(self) -> None:
        body = (
            "#EXTM3U\n"
            "#EXT-X-TARGETDURATION:2\n"
            "#EXTINF:2,\n"
            "segment.ts\n"
            "#EXT-X-ENDLIST\n"
        ).encode("utf-8")
        self.assertTrue(
            parse_media_playlist(
                body, "https://cdn.example.test/live.m3u8"
            ).end_list
        )
        vod = (
            "#EXTM3U\n"
            "#EXT-X-PLAYLIST-TYPE:VOD\n"
            "#EXT-X-TARGETDURATION:2\n"
            "#EXTINF:2,\n"
            "segment.ts\n"
        ).encode("utf-8")
        with self.assertRaisesRegex(PlaylistError, "VOD"):
            parse_media_playlist(
                vod, "https://cdn.example.test/vod.m3u8"
            )


class HTTPAndResolverTests(unittest.TestCase):
    def make_client(self) -> SafeHTTPClient:
        return SafeHTTPClient(
            timeout_seconds=1.0,
            allow_http=True,
            allow_private=True,
        )

    def test_direct_client_follows_redirect_and_validates_byte_range(self) -> None:
        with MutableHLSServer() as server:
            client = self.make_client()
            redirected = client.fetch(
                server.base_url + "/redirect",
                maximum_bytes=4096,
                accept="application/vnd.apple.mpegurl",
            )
            self.assertEqual(redirected.status, 200)
            self.assertTrue(redirected.url.endswith("/master.m3u8"))
            ranged = client.fetch(
                server.base_url + "/range.bin",
                maximum_bytes=4,
                accept="application/octet-stream",
                byte_range=(2, 4),
            )
            self.assertEqual(ranged.body, b"2345")

    def test_direct_client_rejects_incomplete_byte_range(self) -> None:
        with MutableHLSServer() as server:
            with self.assertRaisesRegex(PlaybackError, "length"):
                self.make_client().fetch(
                    server.base_url + "/short-range.bin",
                    maximum_bytes=4,
                    accept="application/octet-stream",
                    byte_range=(2, 4),
                )
            with self.assertRaisesRegex(PlaybackError, "incomplete"):
                self.make_client().fetch(
                    server.base_url + "/short.bin",
                    maximum_bytes=5,
                    accept="application/octet-stream",
                )

    def test_resolver_follows_master_to_live_audio_playlist(self) -> None:
        with MutableHLSServer() as server:
            playlist = PlaylistResolver(self.make_client()).resolve(
                server.base_url + "/master.m3u8"
            )
            self.assertEqual(playlist.target_duration, 2)
            self.assertEqual(playlist.segments[-1].sequence, 12)
            self.assertTrue(playlist.url.endswith("/audio.m3u8"))

    def test_resolver_rejects_finite_playlist(self) -> None:
        class Client:
            def fetch(self, *_args: Any, **_kwargs: Any) -> Any:
                return type(
                    "Response",
                    (),
                    {
                        "url": "https://cdn.example.test/vod.m3u8",
                        "body": (
                            b"#EXTM3U\n#EXT-X-TARGETDURATION:2\n"
                            b"#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n"
                        ),
                    },
                )()

        with self.assertRaisesRegex(PlaylistError, "finite"):
            PlaylistResolver(Client()).resolve(  # type: ignore[arg-type]
                "https://cdn.example.test/vod.m3u8"
            )


class DecoderTests(unittest.TestCase):
    def _fake_ffmpeg(self, directory: Path, succeeds: bool) -> Path:
        executable = directory / ("ffmpeg-ok" if succeeds else "ffmpeg-fail")
        body = """#!/usr/bin/env python3
import struct
import sys
if "-version" in sys.argv:
    sys.stdout.write("ffmpeg version deterministic-test\\n")
    raise SystemExit(0)
payload = sys.stdin.buffer.read()
if not payload or %s:
    sys.stderr.write("no decodable audio\\n")
    raise SystemExit(1)
sys.stdout.buffer.write(struct.pack("<ffff", 0.0, 0.0, 0.0, 0.0))
""" % ("True" if not succeeds else "False")
        executable.write_text(body, encoding="utf-8")
        os.chmod(executable, 0o700)
        return executable

    def test_decoder_proves_an_audio_frame_even_when_samples_are_zero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = self._fake_ffmpeg(Path(directory), True)
            decoder = FFmpegAudioDecoder(str(executable), timeout_seconds=1.0)
            samples = decoder.decode_one_audio_frame(b"init", b"segment")
            self.assertEqual(samples, 4)
            self.assertIn("deterministic-test", decoder.version)

    def test_decoder_rejects_media_without_audio(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = self._fake_ffmpeg(Path(directory), False)
            decoder = FFmpegAudioDecoder(str(executable), timeout_seconds=1.0)
            with self.assertRaisesRegex(DecoderError, "no decodable audio"):
                decoder.decode_one_audio_frame(b"", b"segment")

    def test_decoder_requires_real_absolute_ffmpeg_identity(self) -> None:
        with self.assertRaises(ConfigurationError):
            FFmpegAudioDecoder("ffmpeg")
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "not-ffmpeg"
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            os.chmod(executable, 0o700)
            with self.assertRaises(ConfigurationError):
                FFmpegAudioDecoder(str(executable))

    def test_installed_ffmpeg_decodes_generated_silent_hls_segment(self) -> None:
        executable = shutil.which("ffmpeg")
        if executable is None:
            if os.environ.get("AUTOMIX_REQUIRE_FFMPEG_TEST") == "1":
                self.fail("AUTOMIX_REQUIRE_FFMPEG_TEST requires ffmpeg")
            self.skipTest("ffmpeg is not installed")
        with tempfile.TemporaryDirectory() as directory:
            segment = Path(directory) / "silence.ts"
            generated = subprocess.run(
                [
                    executable,
                    "-v",
                    "error",
                    "-f",
                    "lavfi",
                    "-i",
                    "anullsrc=r=48000:cl=stereo",
                    "-t",
                    "1",
                    "-c:a",
                    "aac",
                    "-f",
                    "mpegts",
                    "-y",
                    str(segment),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10.0,
                check=False,
            )
            self.assertEqual(
                generated.returncode,
                0,
                generated.stderr.decode("utf-8", "replace"),
            )
            decoder = FFmpegAudioDecoder(executable, timeout_seconds=3.0)
            self.assertGreater(
                decoder.decode_one_audio_frame(b"", segment.read_bytes()), 0
            )


class StateAndMonitorTests(unittest.TestCase):
    def make_state(
        self, production_eligible: bool = True
    ) -> EgressHealthState:
        return EgressHealthState(
            "remote-observer",
            "ffmpeg version deterministic-test",
            production_eligible=production_eligible,
            maximum_progress_age_ms=15_000,
        )

    def test_baseline_is_not_health_until_sequence_advances(self) -> None:
        state = self.make_state()
        with mock.patch(
            "hls_health_bridge.epoch_ms", side_effect=[1000, 2000]
        ):
            state.observe_baseline(
                SegmentCursor(10, "10:a"),
                1024,
                "https://cdn.example.test/live.m3u8",
                2,
            )
            baseline = state.payload(now_ms=1500)
            state.observe_progress(
                SegmentCursor(11, "11:b"),
                1024,
                "https://cdn.example.test/live.m3u8",
                2,
            )
        healthy = state.payload(now_ms=2500)
        self.assertFalse(baseline["healthy"])
        self.assertFalse(baseline["streaming"])
        self.assertTrue(healthy["healthy"])
        self.assertTrue(healthy["streaming"])
        self.assertTrue(healthy["audioActive"])
        self.assertEqual(healthy["timestampMs"], 2000)

    def test_stale_progress_and_rehearsal_override_fail_closed(self) -> None:
        state = self.make_state()
        with mock.patch("hls_health_bridge.epoch_ms", return_value=1000):
            state.observe_progress(
                SegmentCursor(11, "11:b"),
                1024,
                "https://cdn.example.test/live.m3u8",
                2,
            )
        stale = state.payload(now_ms=17_000)
        self.assertFalse(stale["healthy"])
        self.assertFalse(stale["streaming"])
        self.assertIn("stale", stale["detail"])

        rehearsal = self.make_state(production_eligible=False)
        with mock.patch("hls_health_bridge.epoch_ms", return_value=1000):
            rehearsal.observe_progress(
                SegmentCursor(11, "11:b"),
                1024,
                "http://127.0.0.1/live.m3u8",
                2,
            )
        payload = rehearsal.payload(now_ms=2000)
        self.assertFalse(payload["healthy"])
        self.assertTrue(payload["streaming"])
        self.assertIn("rehearsal", payload["detail"])

    def test_monitor_requires_real_http_progress_and_decoded_audio(self) -> None:
        with MutableHLSServer() as server:
            client = SafeHTTPClient(
                timeout_seconds=1.0,
                allow_http=True,
                allow_private=True,
            )
            decoder = FakeDecoder()
            state = self.make_state()
            monitor = HLSMonitor(
                server.base_url + "/master.m3u8",
                PlaylistResolver(client),
                client,
                decoder,  # type: ignore[arg-type]
                state,
            )
            monitor.poll_once()
            self.assertFalse(state.payload()["healthy"])
            self.assertEqual(server.segment_requests, ["/audio-12.aac"])

            server.media_sequence = 11
            monitor.poll_once()
            payload = state.payload()
            self.assertTrue(payload["healthy"])
            self.assertEqual(payload["mediaSequence"], 13)
            self.assertEqual(server.segment_requests[-1], "/audio-13.aac")
            self.assertEqual(len(decoder.calls), 2)

    def test_monitor_sequence_reset_rebaselines_and_fails_closed(self) -> None:
        state = self.make_state()
        decoder = FakeDecoder()

        class Resolver:
            def __init__(self) -> None:
                self.sequences = [10, 11, 2]

            def resolve(self, _url: str) -> MediaPlaylist:
                sequence = self.sequences.pop(0)
                segment = SegmentReference(
                    sequence,
                    2.0,
                    MediaReference(
                        f"https://cdn.example.test/{sequence}.aac"
                    ),
                    None,
                )
                return MediaPlaylist(
                    "https://cdn.example.test/audio.m3u8",
                    2,
                    sequence,
                    (segment,),
                    False,
                )

        class Client:
            def fetch(self, *_args: Any, **_kwargs: Any) -> Any:
                return type("Response", (), {"body": b"audio"})()

        monitor = HLSMonitor(
            "https://cdn.example.test/master.m3u8",
            Resolver(),  # type: ignore[arg-type]
            Client(),  # type: ignore[arg-type]
            decoder,  # type: ignore[arg-type]
            state,
        )
        monitor.poll_once()
        monitor.poll_once()
        self.assertTrue(state.payload()["healthy"])
        monitor.poll_once()
        payload = state.payload()
        self.assertFalse(payload["healthy"])
        self.assertFalse(payload["streaming"])
        self.assertIn("reset", payload["detail"])

    def test_monitor_failure_clears_previous_health_immediately(self) -> None:
        state = self.make_state()
        with mock.patch("hls_health_bridge.epoch_ms", return_value=1000):
            state.observe_progress(
                SegmentCursor(11, "11:b"),
                1024,
                "https://cdn.example.test/live.m3u8",
                2,
            )
        self.assertTrue(state.payload(now_ms=1500)["healthy"])
        state.mark_failure("CDN request failed")
        payload = state.payload(now_ms=1500)
        self.assertFalse(payload["healthy"])
        self.assertFalse(payload["streaming"])
        self.assertFalse(payload["audioActive"])
        self.assertEqual(payload["detail"], "CDN request failed")


class HealthHTTPTests(unittest.TestCase):
    def test_health_contract_is_no_store_and_dns_independent(self) -> None:
        state = EgressHealthState(
            "remote-observer",
            "ffmpeg version deterministic-test",
            production_eligible=True,
        )
        with mock.patch("hls_health_bridge.epoch_ms", return_value=1000):
            state.observe_progress(
                SegmentCursor(11, "11:b"),
                1024,
                "https://cdn.example.test/live.m3u8",
                2,
            )
        with mock.patch(
            "socket.getfqdn",
            side_effect=AssertionError(
                "health listener must not perform reverse DNS"
            ),
        ):
            server = EgressHTTPServer(
                ("127.0.0.1", 0), make_health_handler(state)
            )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/health"
            with mock.patch(
                "hls_health_bridge.epoch_ms", return_value=1500
            ), urllib.request.urlopen(url, timeout=1.0) as response:
                body = json.load(response)
                self.assertEqual(response.status, 200)
                self.assertIn("no-store", response.headers["Cache-Control"])
                self.assertEqual(
                    response.headers["X-Content-Type-Options"], "nosniff"
                )
            self.assertTrue(body["healthy"])
            self.assertTrue(body["streaming"])
            self.assertTrue(body["audioActive"])
            self.assertEqual(body["formatVersion"], FORMAT_VERSION)
            self.assertEqual(body["kind"], HEALTH_KIND)
            self.assertNotIn("live.m3u8", json.dumps(body))
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
