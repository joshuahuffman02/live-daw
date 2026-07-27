# Remote Operator Console — Design Spec

Date: 2026-06-20
Component: `native/AutoMixNative` (AutoMix Native macOS app)
Status: Approved design, pending implementation plan

## Goal

Let the operator run a live church service while **out of the room**. The Mac app
already mixes autonomously; this adds a phone/tablet console on the same Wi-Fi that
(1) shows the live mix state, (2) **alerts** when something needs attention, and
(3) allows remote intervention (SAFE, per-channel mute/override, scene change).

This realizes the SPEC's "Supervisory UI … remote monitoring so an operator can
watch/intervene off-site" line for the same-building case.

## Requirements (from brainstorming)

- **Same-Wi-Fi only.** The Mac app runs an embedded web server. No cloud, no
  accounts, works fully offline. (Internet relay is explicitly out of scope but the
  design must not preclude adding it later.)
- **Installable PWA** (Add to Home Screen) so it can fire Web Notifications when
  backgrounded, layered on a loud in-page alarm + full-screen red fault state.
- **Live monitoring:** stream L/R meters, momentary/short/integrated LUFS, limiter
  GR, per-channel input levels, route/health status, dropout/overrun counters,
  watchdog SAFE state, current scene, running/SAFE/FREEZE state.
- **Remote control:** engage/release SAFE; per-channel mute and fader/pan override;
  scene change.
- **Alerting:** the Mac computes authoritative fault conditions and pushes them; the
  phone reacts (red takeover + alarm + notification).
- **Control gated by a pairing code** so random people on church Wi-Fi cannot act.

## Non-goals (YAGNI)

- No internet/off-site access, tunneling, or cloud relay.
- No multi-account/role management. One pairing code per app launch.
- No HTTPS/TLS (LAN-only, self-signed certs cause more phone friction than they
  solve here). Pairing token is the access control; see Security.
- No new audio-thread features. Remote control uses only existing control-rate paths.
- No change to the DSP engine, the headless CLI proof commands, or the desktop UI's
  existing panels (only an additive "Remote Monitoring" panel).

## Architecture (Approach A: native Swift, SSE + POST, zero dependencies)

The app opens a TCP listener with `Network.framework` (`NWListener`). A minimal
HTTP/1.1 layer:

- serves the static PWA files (bundled app resources),
- streams live telemetry over **Server-Sent Events** (`text/event-stream`,
  newline-delimited JSON, browser auto-reconnect),
- accepts **control commands as plain JSON POSTs**.

SSE-down / POST-up avoids all WebSocket framing/masking complexity while giving
~10 Hz live updates. Keeps the appliance 100% dependency-free, matching the current
Core Audio + C++ build (zero third-party deps today).

### Components (new files under `native/AutoMixNative/Network/`)

| Component | Responsibility | Depends on |
|---|---|---|
| `MonitorServer` | Owns `NWListener`, accepts connections, dispatches to `HTTPConnection`. Start/stop lifecycle. Bonjour advertise. | `MonitorService` |
| `HTTPConnection` | Per-connection HTTP/1.1 request parse, route match, response write, SSE keep-alive loop. | `MonitorService` |
| `MonitorService` (protocol) | The boundary the server sees: `currentSnapshotJSON() -> Data`, `apply(_ command: RemoteCommand) -> CommandResult`, `verify(pairingCode:) -> String?` (returns token), `isValid(token:) -> Bool`. | — |
| `TelemetrySnapshot` (Codable) | JSON contract pushed over SSE (see Data contracts). | — |
| `RemoteCommand` (Codable enum) | Commands accepted via POST (see Data contracts). | — |
| `CommandResult` (Codable) | `{ ok: Bool, message: String? }`. | — |
| `AlertEvaluator` | **Pure** function: `evaluate(_ input: AlertInput) -> (alerts: [Alert], severity: Severity)`. All fault logic + thresholds. Unit-testable in isolation. | — |
| `MonitorBridge` | `@MainActor` adapter. Conforms `AppModel` to `MonitorService`: builds `TelemetrySnapshot` from published state, routes `RemoteCommand` to existing `AppModel` methods, owns the pairing/token store. Publishes the snapshot into a lock-guarded box. | `AppModel` |
| `PairingStore` | Per-launch secret, 6-digit code, HMAC token mint/verify, paired-client list, revoke-all. | — |

The static PWA assets live in `native/AutoMixNative/RemoteWeb/` and are added to the
app target as resources (copied into the bundle). The server resolves URL paths to
those bundled files. No build step.

### Threading model & realtime safety

- `NWListener` + all connections run on a dedicated dispatch queue
  (`com.livedaw.automix.monitor`). Telemetry reads never touch the main actor.
- **Telemetry (down):** `AppModel.pollEngine()` already runs at 10 Hz on the main
  actor. It will additionally build a `TelemetrySnapshot` and store its encoded
  `Data` into a lock-guarded box (`os_unfair_lock`) owned by `MonitorBridge`. Each
  SSE client tick reads that pre-encoded `Data` on the server queue — **no main-actor
  hop per tick**, so N connected phones cannot stall the UI or audio.
- **Commands (up):** POST handler decodes `RemoteCommand` on the server queue, then
  hops to `@MainActor` to call the same methods the desktop buttons call, returns
  `CommandResult`. Commands are infrequent; the hop is correct and keeps engine
  control serialized with the desktop UI.
- **RT-safety (non-negotiable, per SPEC hard constraints):** the server never touches
  the audio callback. It reads already-published atomic meters/counters and issues
  control-rate changes only through existing paths (`safeBypass` atomic,
  `channelDidChange` → `BrainThread` mailbox, `selectedScene`). Two-rate separation
  is preserved; a flaky phone on Wi-Fi can never affect audio.

### HTTP endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/` and static paths (`/app.js`, `/style.css`, `/manifest.webmanifest`, `/sw.js`, `/icons/*`) | none | Serve the PWA shell. |
| GET | `/events` | none (view) | SSE stream of `TelemetrySnapshot` at ~10 Hz + immediate first frame. |
| POST | `/pair` | code in body | Body `{code}`; on match returns `{token}` and sets it as a cookie. |
| POST | `/command` | token | Body = `RemoteCommand`; returns `CommandResult`. 401 without a valid token. |
| GET | `/health` | none | `{ ok: true, name, version }` for discovery/debugging. |

## Data contracts

### TelemetrySnapshot (server → phone, SSE)

```jsonc
{
  "ts": 1718900000000,            // ms, supplied by Swift (Date in app, not in workflow)
  "venueName": "AutoMix Native",  // from profile/host name
  "isRunning": true,
  "safe": false,                  // operator SAFE bypass
  "freeze": false,
  "watchdogSafe": false,
  "scene": "worship",             // MixScene.rawValue
  "scenes": ["worship","sermon","patch","masking","console"],
  "sampleRate": 96000,
  "inputChannelCount": 64,
  "stream": { "l": -7.2, "r": -7.6, "momentaryLufs": -14.2,
              "shortLufs": -14.0, "integratedLufs": -14.1, "limiterGrDb": -1.2 },
  "counters": { "dropouts": 0, "callbackOverruns": 0, "deadlineMisses": 0,
                "outputUnderruns": 0, "outputOverruns": 0,
                "lastCallbackFrames": 256, "maxCallbackFrames": 256 },
  "channels": [
    { "idx": 0, "name": "Pastor", "role": "speech", "levelDb": -22.0,
      "muted": false, "faderOverride": false, "faderDb": 0.0,
      "panOverride": false, "pan": 0.0 }
  ],
  "alerts": [
    { "id": "stream-silent", "severity": "critical", "title": "Stream silent",
      "detail": "No audio on stream L/R · 4s",
      "actions": ["engageSafe"] }
  ],
  "fault": true,                  // any critical present
  "severity": "critical"          // max severity across alerts: none|info|warning|critical
}
```

The snapshot is pre-encoded to `Data` once per 10 Hz tick and shared by all clients.

### RemoteCommand (phone → server, POST `/command`)

```jsonc
// one of:
{ "type": "setSafe", "on": true }
{ "type": "setFreeze", "on": true }
{ "type": "setScene", "scene": "sermon" }
{ "type": "setMute", "idx": 7, "on": true }
{ "type": "setFaderOverride", "idx": 7, "on": true, "db": -6.0 }
{ "type": "setPanOverride", "idx": 7, "on": true, "pan": -0.3 }
{ "type": "clearOverride", "idx": 7 }      // clears fader+pan override, unmutes
```

### Command → AppModel mapping (reuse existing paths, no new audio code)

| Command | AppModel action |
|---|---|
| `setSafe` | set `safeBypass` (existing atomic path) |
| `setFreeze` | set `frozen` |
| `setScene` | set `selectedScene` (drives BrainThread + profile save) |
| `setMute` | on `ChannelMapping`: set `faderOverrideEnabled = true`, `faderDb = -80` (the floor = effectively silent); track `muted` flag separately so unmute can restore prior fader. Then `channelDidChange`. |
| `setFaderOverride` | set `faderOverrideEnabled`, clamp `faderDb` to `-80...12`, `channelDidChange` |
| `setPanOverride` | set `panOverrideEnabled`, clamp `pan` to `-1...1`, `channelDidChange` |
| `clearOverride` | clear fader+pan override + muted, `channelDidChange` |

`muted` is a remote-console concept layered on the existing fader override (no DSP or
bridge change). `ChannelMapping` gains a `muted: Bool` (persisted in the venue profile
like the other overrides) and a stored `preMuteFaderDb` so unmute restores the prior
value. Mute = fader override at the
−80 dB floor, which the bridge already honors and which existing tests already cover
for the fader path.

## AlertEvaluator (authoritative fault logic)

Pure function over an `AlertInput` value built from the snapshot fields + small bits
of running history (timers for "sustained for N s"). Thresholds in one
`AlertThresholds` struct so they're tunable and testable.

| Alert id | Trigger | Severity |
|---|---|---|
| `stream-silent` | running && stream L and R < −90 dB sustained > 2s | critical |
| `watchdog-safe` | `watchdogSafe == true` | critical |
| `engine-stopped` | was running, now `isRunning == false` unexpectedly | critical |
| `xrun` | any counter delta > 0 since last tick | warning |
| `clipping` | stream L or R ≥ −0.1 dB sustained > 1s | warning |
| `loudness-band` | integrated LUFS outside −20…−9 sustained > 10s (running) | warning |
| `route-drift` | sample rate / channel count / format / output isolation changed while running (from `statusText` health flags) | warning |
| `dead-channel` | a role-assigned channel < −90 dB while ≥1 peer in same role group active, sustained > 5s | info |
| `link-lost` | client-side only: SSE `onerror`/no frame > 3s | warning |

`fault = any critical`. `severity = max over alerts`. Sustained-timers live in the
evaluator's small mutable state (not pure across calls, so it's a stateful struct with
a pure `step(input, nowMs)`; nowMs passed in for testability).

The phone escalates by severity: info = quiet badge; warning = amber banner; critical
= red takeover + alarm + Web Notification.

## Security / pairing

- On app launch `PairingStore` generates a per-launch random secret and a 6-digit
  code. The Mac UI shows the code, the `http://<host>.local:<port>` URL, and a QR
  encoding the URL.
- `POST /pair {code}` with the right code returns a token = HMAC-SHA256(secret,
  clientNonce+issuedAt), set as an `HttpOnly` cookie. `MonitorBridge` keeps the set of
  valid tokens (paired clients) with a label + first-seen time.
- `GET /events` and static assets are open (view-only). `POST /command` requires a
  valid token → 401 otherwise. The phone shows "Pair to control" until paired.
- Mac UI lists paired/connected clients and has "Revoke all" (clears tokens; phones
  drop to view-only and must re-pair).
- Tokens die on app restart (secret regenerates). Acceptable: a service is one launch.

QR generation uses `CoreImage` `CIQRCodeGenerator` (system framework, no dependency).

## PWA structure (`RemoteWeb/`, zero build step)

- `index.html` — shell; loads `style.css`, `app.js`; links `manifest.webmanifest`.
- `app.js` — opens `EventSource('/events')`, renders snapshot, handles pairing,
  sends commands via `fetch('/command')`, manages alarm audio + notifications +
  fault takeover. Vanilla JS, no framework.
- `style.css` — phone-first; dark, high-contrast for a dim booth; large tap targets.
  Visual language borrowed from the existing `web/` POC (meters, color thresholds).
- `manifest.webmanifest` — name, icons, `display: standalone` (enables Add to Home
  Screen).
- `sw.js` — caches the shell for offline; handles notification click → focus. (Live
  data is SSE, not cached.)
- `icons/` — app icons (generated PNGs).
- Alarm: a short looping WebAudio tone (generated in JS, no asset) + optional bundled
  sound; plays on critical; "Dismiss · silence alarm" stops it until the next
  distinct fault.
- Notifications: request permission on first pair; on a new critical alert call
  `registration.showNotification(...)` (works while backgrounded once installed).

## Mac UI additions

A new `GroupBox("Remote Monitoring")` in the existing `DeviceControlPanel`
(`ContentView.swift`), additive only:

- Toggle: Remote Monitoring On/Off (default On).
- Shows URL `http://<host>.local:<port>`, the 6-digit pairing code, and the QR image.
- Connected/paired client count; "Revoke all" button.
- Status line: listening / port-in-use error / off.

`AppModel` gains a `MonitorBridge` instance, started/stopped with the toggle, fed by
`pollEngine()`.

## File layout (new)

```
native/AutoMixNative/Network/
  MonitorServer.swift
  HTTPConnection.swift
  MonitorService.swift          // protocol + RemoteCommand + CommandResult + TelemetrySnapshot + Alert types
  AlertEvaluator.swift
  PairingStore.swift
  MonitorBridge.swift           // AppModel adapter + snapshot box
native/AutoMixNative/RemoteWeb/
  index.html  app.js  style.css  manifest.webmanifest  sw.js  icons/*
native/AutoMixNativeTests/
  AlertEvaluatorTests.swift
  HTTPRequestParsingTests.swift
  PairingStoreTests.swift
  RemoteCommandRoutingTests.swift
  MonitorSnapshotCodableTests.swift
```

`project.yml` already globs `AutoMixNative` sources by path, so new Swift files are
picked up by `xcodegen generate`. `RemoteWeb/` must be added as a resource (folder
reference / copy) so files land in the bundle — to verify after generation.

## Testing strategy

Unit (XCTest, no hardware, runs in existing CI command):

1. `AlertEvaluator` — table-driven: each condition fires at the right threshold,
   clears when resolved, respects sustained timers (inject `nowMs`), and `severity`
   is the max. The highest-value tests; this is the brain of the feature.
2. HTTP request parsing — valid/partial/malformed requests, header parse, method +
   path routing, body length handling.
3. `PairingStore` — right code → token; wrong code → nil; token verify; revoke-all
   invalidates; tokens differ per launch secret.
4. `RemoteCommand` routing — each command maps to the right `AppModel` mutation
   (drive a `MonitorBridge` against an `AppModel` in simulation; assert state).
   Mute sets fader override to −80 and unmute restores; clamps applied.
5. `TelemetrySnapshot`/`RemoteCommand` Codable round-trips and the exact JSON key
   contract (guards the phone/Swift wire format).

Integration smoke (headless, optional CLI flag, mirrors existing `--smoke-test`
style): a new `--monitor-smoke` that starts the server on an ephemeral port, hits
`/health`, `/pair`, `/events` (reads ≥1 frame), and `/command` (round-trips a SAFE
toggle), then exits nonzero on any failure. Lets us prove the server end-to-end with
no phone and no rig.

Manual (documented in `native/README.md`): start app, open the URL on a phone, pair,
watch the simulated engine, trigger SAFE/mute, Add to Home Screen, and force a fault
(e.g. stop the engine) to see the alarm + notification.

## Build / verification

```bash
cd native && /opt/homebrew/bin/xcodegen generate && cd ..
xcodebuild -project native/AutoMixNative.xcodeproj -scheme AutoMixNative \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project native/AutoMixNative.xcodeproj -scheme AutoMixNative \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/AutoMix Native.app/Contents/MacOS/AutoMix Native" -print -quit)
"$APP" --monitor-smoke
```

Success = build clean, all existing 122 tests + new tests pass, `--monitor-smoke`
exits 0, and a phone on the LAN can monitor + pair + control + receive a fault alert.

## Future (explicitly deferred)

- Internet/off-site access via a relay or tunnel + stronger auth. The
  `MonitorService` boundary and token model are designed so a relay transport can be
  added without touching `AppModel`/DSP.
- True background push (APNs) — needs the cloud relay above.
- A proper DSP-level mute (vs. fader-floor) if −80 dB ever proves insufficient.

## Notes / constraints honored

- No external dependencies added (Network, CoreImage, CryptoKit are system).
- No audio-thread changes; control-rate only; two-rate separation intact.
- Manual override semantics unchanged (remote uses the same override paths).
- SAFE/failsafe remains always-available; remote adds a second way to engage it.
- `Date`/randomness used only in the running app (Swift), never in any workflow
  script context.
