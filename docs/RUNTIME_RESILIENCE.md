# Runtime Resilience and Livestream Health

AutoMix has three recovery boundaries. They solve different failures and should all
be present on a production rig.

## 1. Realtime and Core Audio recovery

Automatic Audio Recovery is armed only after a successful engine start. It watches:

- exact configured input/output route readiness;
- input and output callback age;
- separate-device output-ring fill and bounded clock correction;
- recorder overflow, watchdog SAFE, and route-health transitions.

A failure must remain unhealthy for two seconds. Recovery then stops and reopens the
exact configured route, reapplies scene/SAFE/FREEZE/SHADOW/manual controls, and
verifies the result for three seconds. Failed attempts back off at 1, 2, 5, 10, 30,
then 60 seconds. Operator Stop always disarms the coordinator. If continuous capture
was requested, recovery opens a new checkpointed recording directory.

Incidents are append-only JSON Lines at:

`~/Library/Application Support/AutoMix Native/Incidents/runtime-incidents.jsonl`

The audio callback never writes this file.

Staged promotion snapshots the proof-window subset and source-journal provenance
using the contract in `RUNTIME_INCIDENT_EVIDENCE.md`. Informational lifecycle events
are retained, while any warning or critical incident blocks a clean acceptance run.

## 2. Application relaunch

While Automatic Audio Recovery is armed, AutoMix atomically saves an
`AutonomousSession.json` marker. It records whether continuous capture should resume.
Operator Stop or disabling Automatic Audio Recovery removes the marker.

Install the included per-user LaunchAgent after copying a signed release app to its
permanent location:

```sh
./scripts/install-automix-launch-agent.sh "/Applications/AutoMix Native.app"
```

The agent starts the app at user login and relaunches it after a crash or abnormal
exit, with a five-second throttle. On launch, the app resumes only when the autonomous
session marker is present. The saved venue profile still has to pass the normal
permission, route, clock, format, channel, role, and isolation gates.

Do not move the app after installing the LaunchAgent. Re-run the installer if the app
path changes. A LaunchAgent is not a replacement for the independent hardware backup
in `docs/EXTERNAL_FAILOVER.md`.

## 3. External primary-audio heartbeat

The Remote Monitoring server's token-free `/health` endpoint is fail-closed for an
external relay/controller. It returns HTTP 200 only for the exact non-simulated
64-channel/96 kHz HD96/Dante route, isolated output, running engine, fresh input and
output callbacks, and a control-loop update no older than one second. Any failed
condition returns HTTP 503; a crashed app or Mac is unreachable. The external
controller must poll at least twice per second with a request timeout no longer than
one second, select and latch backup on any non-200, stale, malformed, or unreachable
result, and allow return to primary only by operator action. See
`EXTERNAL_FAILOVER.md` for the complete topology and contract.

## 4. Encoder and public-egress probes

The optional Encoder Health and Public Egress fields poll every two seconds while the
audio engine is running. Each URL must be token-free HTTP(S) and return a fresh JSON
document:

```json
{
  "healthy": true,
  "streaming": true,
  "audioActive": true,
  "timestampMs": 1785182400000,
  "detail": "primary ingest live"
}
```

`timestampMs` is Unix epoch milliseconds and must be no more than 15 seconds old.
HTTP errors, malformed/stale responses, `healthy:false`, `streaming:false`, or
`audioActive:false` become a critical remote alert after three sustained seconds and
are written to the incident journal. A fresh healthy response records recovery.

Use an encoder/sidecar endpoint for the first probe and an independently observed
platform/CDN playback endpoint for the second. A generic web page returning HTTP 200
does not prove a stream is live and does not satisfy this contract.

For OBS, use the repository's dependency-free
`encoder/obs_health_bridge.py` and per-user LaunchAgent installer. The bridge
authenticates to OBS WebSocket v5 on loopback, polls `GetStreamStatus`, verifies
byte/frame/duration counter progress and clean encoder intervals, checks that the
configured input remains assigned to the chosen streaming track, and requires fresh
`InputVolumeMeters` events for that exact name or UUID. It fails closed for
disconnects, stopped/reconnecting output, stalled counters, skipped frames, high
congestion, stale or malformed status/track/meter data, a missing/wrong carrier,
disabled/bad authentication, and protocol errors. Installation and the distinction
between carrier presence and program content are documented in
`encoder/README.md`. Configure the resulting `http://127.0.0.1:8421/health` URL as
Encoder Health; the Public Egress URL must remain an independent platform/CDN
observer.

The staged proof persists the payload booleans, endpoint timestamp, calculated age,
and request timestamp for both probes. The signed-acceptance contract in
`STREAM_HEALTH_EVIDENCE.md` requires fresh, gap-bounded, all-healthy coverage across
the requested soundcheck and stability window; one isolated unhealthy observation
remains reviewable but cannot be promoted.

## Acceptance drill

Before go-live, record evidence for each:

1. Stall the input callback and verify the engine restarts after the grace period.
2. Remove and restore the output device; verify bounded retry/backoff and recovery.
3. Keep continuous capture active through a forced engine failure; verify a new
   recording directory and valid WAV headers.
4. Stop/reconnect OBS, remove the configured OBS program-audio input, and return
   stale/unhealthy encoder JSON; verify the bridge, desktop, and remote paths fail
   closed and recover only after fresh exact-input meter and stream-status evidence.
5. Kill the app abnormally; verify LaunchAgent relaunch and session/capture resume.
6. Click operator Stop; verify no automatic engine restart.
7. Run every external-failover kill test and remain on backup until manual return.

Record all seven results and their attachments in the `runtime-resilience` JSON
contract in `PRODUCTION_EVIDENCE_FORMAT.md`. The signed acceptance path requires each
named drill, rejects duplicates or substitutions, and checks the critical
test-specific observations rather than accepting an opaque attachment.
