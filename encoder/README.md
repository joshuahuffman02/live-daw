# OBS encoder health bridge

`obs_health_bridge.py` converts the installed OBS WebSocket v5 state into the
strict JSON contract consumed by AutoMix Native and the staged hardware-proof
runner. It uses only the Python 3 standard library and binds both OBS and its HTTP
health endpoint to loopback.

This is the **encoder** observation. It does not replace the independently observed
public-platform/CDN **egress** endpoint; deploy the repository's viewer-side HLS
observer as documented in [`../egress/README.md`](../egress/README.md).

## What it proves

The bridge reports healthy only while all of these remain true:

- the OBS WebSocket upgrade, JSON subprotocol, RPC v1 negotiation, and password
  challenge succeed;
- `GetStreamStatus` is fresh, the stream output is active, and OBS is not
  reconnecting;
- byte, frame, and duration counters advanced since the previous poll, with no new
  skipped frames and congestion below the fail-closed threshold;
- the exact configured program-audio input remains assigned to the selected OBS
  streaming audio track;
- high-volume `InputVolumeMeters` events are fresh and contain the exact configured
  program-audio input name or UUID with valid channel meter data.

`audioActive` means the selected OBS audio carrier exists and is producing fresh
meter frames. It intentionally remains true during digital silence: a sermon pause
is not an encoder failure. AutoMix's own program-silence alert and the independent
egress probe cover missing content farther down the chain.

Any disconnect, bad authentication, request error, wrong/missing input, malformed
frame, stale status/meter, stopped stream, or reconnecting output immediately clears
health. A server-initiated OBS `SessionInvalidated` close never auto-reconnects; the
bridge must be restarted as required by the OBS protocol.

## Configure OBS

1. In OBS, open **Tools → WebSocket Server Settings**.
2. Enable the WebSocket server on loopback port `4455`.
3. Keep authentication enabled and use a generated password. Do not put that
   password in a command line, venue profile, repository, or shell history.
4. Give the BlackHole/capture source receiving AutoMix a stable, unique name such as
   `AutoMix Program`. Confirm it appears in the OBS Audio Mixer and is assigned to
   the streaming track.
5. Put the WebSocket password in a temporary owner-only file:

```sh
umask 077
/usr/bin/touch "$HOME/Desktop/obs-websocket-password"
/bin/chmod 600 "$HOME/Desktop/obs-websocket-password"
```

Open that file in a local editor, paste only the password on one line, and save it.
The installer copies it into an owner-only Application Support directory.

## Install on macOS

From the repository:

```sh
./scripts/install-obs-health-bridge.sh \
  --password-file "$HOME/Desktop/obs-websocket-password" \
  --audio-input-name "AutoMix Program" \
  --audio-track 1
```

For a UUID-bound deployment, use `--audio-input-uuid` instead. The installer:

- copies the dependency-free bridge and password to
  `~/Library/Application Support/AutoMix OBS Health/`;
- verifies the password file and configuration;
- installs/restarts the per-user `com.livedaw.obshealthbridge` LaunchAgent;
- writes owner-only logs under `~/Library/Logs/AutoMix OBS Health/`;
- confirms the loopback HTTP server is reachable.

The endpoint is:

```text
http://127.0.0.1:8421/health
```

Set AutoMix Native's **Encoder Health URL** to that exact URL. Configure **Public
Egress Health URL** with the separate platform/CDN playback observer.

An unhealthy bridge still returns HTTP 200 with `healthy:false` and a fresh,
machine-readable reason. This distinguishes “the observer is alive and detected a
fault” from “the observer process is unreachable”; both fail AutoMix health and
hardware-proof gates.

Example healthy payload:

```json
{
  "formatVersion": 1,
  "kind": "automix-obs-encoder-health",
  "healthy": true,
  "streaming": true,
  "audioActive": true,
  "timestampMs": 1785277200000,
  "detail": "OBS 32.2.1 streaming; AutoMix Program carrier fresh on track 1; peak -31.4 dBFS"
}
```

Extra diagnostic fields include connection/authentication state, OBS versions,
reconnect state, stream/track/meter ages, selected input and audio track, encoder
counter progress, skipped frames, congestion, peak level, and session generation.
AutoMix safely ignores those additions.

## Manual run

The LaunchAgent is preferred for production. For a foreground diagnostic:

```sh
python3 encoder/obs_health_bridge.py \
  --password-file "/private/path/obs-websocket-password" \
  --audio-input-name "AutoMix Program"
```

Authentication is mandatory by default. `--allow-unauthenticated` exists only to
diagnose a rehearsal OBS instance and deliberately cannot produce
`healthy:true`.

## Verify

```sh
python3 -W error::ResourceWarning -m unittest -v \
  encoder/test_obs_health_bridge.py
```

The deterministic suite covers the authentication vector, owner-only secret file,
loopback confinement, WebSocket upgrade/subprotocol/masking, request binding,
authenticated and unauthenticated negotiation, exact name/UUID carrier and track
selection, advancing encoder counters, skipped-frame/congestion failure, honest
observation timestamps, stale and malformed data, immediate stream-stop/reconnect
failure, recovery, OBS session invalidation, socket cleanup, and the no-store HTTP
contract. It does not replace a real OBS stream plus BlackHole/capture-device and
CDN playback drill.
