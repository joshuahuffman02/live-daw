# Public HLS egress observer

`hls_health_bridge.py` is the viewer-side half of AutoMix stream health. Run it on
a machine and Internet connection separate from the streaming Mac. It follows a
public HTTPS HLS master/media playlist, proves that the CDN media sequence advances,
downloads the newest completed segment, decodes an audio frame with FFmpeg, and
serves the strict AutoMix public-egress JSON contract.

This is intentionally independent from
[`../encoder/obs_health_bridge.py`](../encoder/obs_health_bridge.py):

- the OBS bridge proves local encoding and the exact program-audio carrier;
- this observer proves that a public playback client can retrieve advancing,
  decodable program audio from the platform/CDN.

A copy of this process on the streaming Mac or the streaming venue's only Internet
connection is useful for rehearsal, but is not independent production evidence.

## What healthy proves

The observer reports `healthy:true` only after all of these are true:

- the private root URL and every redirect, nested playlist, initialization map, and
  media segment resolve through the configured public HTTPS path;
- DNS resolves to, and the socket actually reaches, a globally routable peer;
- a live HLS media playlist exists without `EXT-X-ENDLIST`;
- the latest media sequence advances beyond an independently decoded baseline;
- the newest completed CDN segment is downloadable within strict size/time limits;
- FFmpeg decodes at least one audio frame from that segment; and
- the last verified sequence advance is no more than 15 seconds old.

`audioActive` means an audio carrier was present and decodable. It intentionally
remains true for a valid digital-silence frame: a normal sermon pause is not a CDN
failure. AutoMix's program-silence alert separately detects missing content.

Master playlists, separate default audio renditions, multiplexed low-bandwidth
variants, media-sequence delta skips, initialization maps, and explicit/implicit HLS
byte ranges are supported. Encrypted media is rejected rather than handled
incorrectly. If the platform exposes only an authenticated player page, DASH, DRM,
or an expiring URL that cannot be refreshed operationally, use a platform-specific
observer instead of weakening this proof.

## Requirements

Install Python 3 and FFmpeg on the **observer Mac**:

```sh
brew install ffmpeg
```

Obtain the platform's actual public HLS master or audio/media playlist URL. Do not
use the ingest URL, OBS local preview, channel web page, or a generic status page.

Put the URL in an owner-only file. Query-string credentials are permitted in this
private file and are never placed in process arguments, health JSON, or logs:

```sh
umask 077
/usr/bin/touch "$HOME/Desktop/public-hls-playback-url"
/bin/chmod 600 "$HOME/Desktop/public-hls-playback-url"
```

Open the file in a local editor, paste exactly one HTTPS URL on one line, and save.

## Install on the observer Mac

For a loopback-only rehearsal:

```sh
./scripts/install-hls-egress-observer.sh \
  --playlist-url-file "$HOME/Desktop/public-hls-playback-url" \
  --observer-site "offsite-rehearsal-mac"
```

For AutoMix to poll the observer over a private VPN address:

```sh
./scripts/install-hls-egress-observer.sh \
  --playlist-url-file "$HOME/Desktop/public-hls-playback-url" \
  --observer-site "offsite-cellular-observer" \
  --listen-host "0.0.0.0" \
  --listen-port 8422 \
  --allow-remote-health
```

The remote health listener has no application credential because the existing
AutoMix contract requires a token-free URL. Never expose it directly to the public
Internet. Restrict port `8422` to the streaming Mac with a VPN and host firewall
ACL. Record the observer host, network/ISP, VPN path, and firewall rule in the
production evidence.

The installer:

- validates the production HTTPS/public-address policy and real FFmpeg identity;
- copies the observer and private URL into
  `~/Library/Application Support/AutoMix HLS Egress/`;
- installs/restarts the per-user `com.livedaw.hlsegresshealth` LaunchAgent;
- writes owner-only logs under `~/Library/Logs/AutoMix HLS Egress/`; and
- confirms the health HTTP process is reachable.

Configure AutoMix Native's **Public Egress Health URL** with the observer's
VPN/firewall-protected address:

```text
http://OBSERVER_VPN_IP:8422/health
```

Keep the local OBS endpoint at `http://127.0.0.1:8421/health` in **Encoder Health
URL**. The staged proof requires both endpoints throughout the complete run.

## Health behavior

The first valid segment establishes a decoded baseline but remains unhealthy. A
later media-sequence advance and successful audio decode are required before the
observer becomes healthy. This prevents a cached or finite clip from masquerading
as a live stream.

Example:

```json
{
  "formatVersion": 1,
  "kind": "automix-hls-egress-health",
  "productionEligible": true,
  "healthy": true,
  "streaming": true,
  "audioActive": true,
  "timestampMs": 1785280000000,
  "detail": "public HLS advancing via cdn.example.test; sequence 19284; decoded 2048 audio samples",
  "observerSite": "offsite-cellular-observer",
  "playbackHost": "cdn.example.test",
  "mediaSequence": 19284,
  "decodedAudioSamples": 2048,
  "ffmpegVersion": "ffmpeg version 8.1.2"
}
```

Diagnostic additions disclose the observer label, playback hostname (never the
full URL), media sequence, progress age, target duration, decoded sample count,
FFmpeg version, and poll generation. AutoMix and the signed proof path require the
production eligibility, stable observer identity/software, non-local playback host,
media sequence, and positive decoded sample evidence shown above.

Any DNS/TLS/HTTP/redirect error, private peer, oversized or malformed playlist,
finite stream, encryption, sequence reset, stalled sequence, missing media,
malformed byte range, or audio decode failure immediately clears health.

`--allow-rehearsal-http-private-playback` exists for a local fixture only. Its
payload is permanently `productionEligible:false` and can never report
`healthy:true`.

## Verify

```sh
AUTOMIX_REQUIRE_FFMPEG_TEST=1 \
  python3 -W error::ResourceWarning -m unittest -v \
  egress/test_hls_health_bridge.py
```

The deterministic suite covers URL/peer confinement, redirect and range handling,
master/audio selection, sequence/delta/map/range parsing, encrypted/finite
rejection, owner-only URL storage, real and fake FFmpeg decoding (including digital
silence), baseline/progression/stall/reset behavior, playback failures, URL
redaction, DNS-independent health startup, and the no-store HTTP contract.

The implementation follows [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216) for
HLS sequencing, maps, and byte ranges, and uses FFmpeg's documented audio stream
mapping and `-frames:a` decoding path. Software tests do not replace the required
offsite public-platform drill.
