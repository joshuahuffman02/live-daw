# AutoMix Native — Apple Silicon macOS app

This folder contains the native production app target for the HD96/Dante livestream
workflow. It keeps the browser app as a prototype/reference and moves the real audio
path into a macOS `.app`:

- SwiftUI operator surface for device selection, status, channel mapping, meters,
  scenes, Keychain-backed Planning Center cue driving, complete manual channel
  processing,
  SAFE, FREEZE, SHADOW, soundcheck recording, and segmented continuous
  multitrack/program capture.
- Objective-C++ Core Audio bridge for Dante Virtual Soundcard / Dante hardware exposed
  as Core Audio devices.
- Existing C++ `bdsp::Engine` and `app::BrainThread` as the mixer core.
- Apple Silicon only for this milestone (`ARCHS=arm64`).

## Build

```bash
cd native
/opt/homebrew/bin/xcodegen generate
cd ..
xcodebuild -project native/AutoMixNative.xcodeproj \
  -scheme AutoMixNative \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Native XCTest bridge validation:

```bash
xcodebuild test -project native/AutoMixNative.xcodeproj \
  -scheme AutoMixNative \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  CODE_SIGNING_ALLOWED=NO
```

The built app lands under Xcode DerivedData, for example:

```text
~/Library/Developer/Xcode/DerivedData/AutoMixNative-*/Build/Products/Debug/AutoMix Native.app
```

## Production release

Release builds enable Hardened Runtime and the CoreAudio input entitlement. A
production artifact must use a valid Developer ID Application identity, Apple
notarization, and a stapled ticket:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: ORGANIZATION (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="automix-notary" \
./scripts/build-notarized-release.sh
```

The release builder refuses dirty source, unsigned output, a missing audio-input
entitlement, failed notarization, and Gatekeeper rejection. It writes the notarized
app, ZIP, SHA-256 digest, build metadata, extracted signed entitlements, and notary
result under `native/build/release/`. Install the app at its permanent path, then
enable crash relaunch:

```bash
sudo ditto "/exact/release/path/AutoMix Native.app" "/Applications/AutoMix Native.app"
./scripts/install-automix-launch-agent.sh "/Applications/AutoMix Native.app"
```

The LaunchAgent installer also fails closed on an invalid signature, missing
notarization ticket, or Gatekeeper rejection. `ALLOW_UNNOTARIZED_AUTOMIX=1` is
available only for deliberate local rehearsal with a non-production build.
The native app does not link JUCE; the licensing boundary between it, external DVS,
and the optional JUCE shell is recorded in
[`../docs/RELEASE_COMPLIANCE.md`](../docs/RELEASE_COMPLIANCE.md).

Headless launch/device-enumeration smoke test:

```bash
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/AutoMix Native.app/Contents/MacOS/AutoMix Native" -print -quit)
"$APP" --smoke-test
```

Headless on-rig Core Audio validation:

```bash
# First list Core Audio UIDs and verify DVS/stream output show format OK.
"$APP" --smoke-test

# Then write a no-audio inventory JSON that scores 96 kHz input candidates, stereo
# stream output candidates, float-format readiness, and output isolation against the
# selected Dante/HD96 input.
"$APP" --smoke-test --write-device-inventory \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"

# Then run the one-shot HD96/Dante validation. If --profile is omitted, the app tries
# the saved UI venue profile from Application Support for device UIDs, channel map,
# expected input count, and scene. The command writes inventory, preflight,
# soundcheck, stability, and full-check manifest JSON artifacts.
"$APP" --smoke-test --write-service-profile \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --scene worship \
  --profile "$HOME/Desktop/AutoMix-HD96-Proof/VenueProfile.json"

"$APP" --smoke-test --core-audio-full-check \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --profile "$HOME/Desktop/AutoMix-HD96-Proof/VenueProfile.json" \
  --soundcheck-seconds 10 \
  --stability-seconds 300 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"

"$APP" --smoke-test --verify-full-check \
  --manifest "$HOME/Desktop/AutoMix-HD96-Proof/automix-core-audio-full-check-YYYYMMDD-HHMMSS.json"

# The same checks can be split apart when diagnosing one phase.
"$APP" --smoke-test --core-audio-preflight \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"

"$APP" --smoke-test --core-audio-soundcheck \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --soundcheck-seconds 10 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"

# For separate-device drift/dropout proof, run the longer non-recording monitor.
"$APP" --smoke-test --core-audio-stability \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --stability-seconds 300 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"
```

The Core Audio preflight writes a no-audio JSON route check before opening the engine.
The standalone soundcheck and stability commands run that same preflight first and
stop before opening Core Audio if the route is not ready. The full-check command stops
after a failed preflight but still writes a manifest with the failure reason. Output
Isolation is blocking for hardware proof: use a stream encoder, BlackHole, Loopback,
OBS/virtual output, capture device, or known-good Aggregate Device output, not the
same Dante/HD96-facing Core Audio route used for the input split. Generic local
outputs such as built-in speakers do not count as hardware-proof livestream routes.
Preflight also blocks when the saved Dante input map is not one-to-one for the
detected HD96 input count or the saved profile has no assigned source roles for the
autonomous mixer. The native Start action refuses to open Core Audio when route-safety
checks fail, including unsafe same-Dante output routes, sample-rate/channel-count
mismatches, unsupported Core Audio formats, input/output clock problems, and
duplicate/missing Dante input-map assignments. The
soundcheck starts with SAFE bypass enabled and records raw inputs plus stream L/R; the
report verifies that SAFE was enabled for the proof recording and Watchdog SAFE stayed
inactive. The
stability monitor waits for active, non-clipping stream L/R before starting the proof
window, then runs the normal mix path with operator SAFE bypass and FREEZE disabled.
UI-generated soundcheck, stability, and proof
manifest artifacts are stamped with the Core Audio route opened at engine start, not a
later picker selection. Passing
on-rig reports and the full-check manifest must say
`validationSource=core-audio-device` and the full-check manifest must say
`hardwareProofPassed=true`; simulator reports intentionally say
`validationSource=simulated-hd96-dante`.
The manifest also requires the no-audio device inventory, preflight, soundcheck WAV,
soundcheck report, and stability report paths before its aggregate `passed` flag can
be true.
Inventory JSON retains general `readyInputUIDs` / `readyOutputUIDs` for rehearsal
diagnostics, but separately records production-ready input/output UIDs and simulated
device UIDs. The semantic verifier re-derives all three lists from the enumerated
device identities, rejects missing or edited production fields for hardware proof,
and rejects a simulated route relabeled as `core-audio-device`.
The one-shot `--core-audio-full-check` command runs the same semantic verifier before
it returns and exits nonzero unless `hardwareProofPassed=true`. Use
`--verify-full-check` to re-run that final gate for an existing manifest; it verifies
referenced files exist and are non-empty, parses the inventory, preflight, soundcheck
report, stability report, and WAV metadata, cross-checks them against the manifest,
requires the inventory's selected input and output UIDs to match the manifest route,
verifies the exact same channel map, source roles, and manual override values appear
in preflight, soundcheck, and stability proofs, requires every embedded soundcheck and
stability report check to pass, requires soundcheck SAFE-bypass proof plus stability
SAFE/FREEZE-disabled proof, and exits nonzero unless
`hardwareProofPassed=true`.

The UI Soundcheck and Stability Monitor panels can also be used for a manual proof
run. After both reports exist, the Hardware Proof panel writes the same no-audio
device inventory, wrapped preflight proof artifact, and full-check manifest shape into
Application Support, then runs the same semantic verifier before showing proof status.
Route, scene, expected channel count, and input-map changes clear stale proof evidence
before another manifest can be saved.

The **Continuous Capture** panel writes raw inputs in physical Core Audio/Dante order
plus final stream L/R to unique, checkpointed 60-second float-WAV segments. Its
two-second preallocated ring and dedicated file queue prevent disk I/O from blocking
the audio callback; any recorder overflow is counted and shown as `Dropped Frames`.
The app can start capture with the engine, requires planned-duration capacity plus a
free-space reserve, monitors that reserve every 30 seconds, and can move only cleanly
completed expired sessions to Trash. At 64 inputs and 96 kHz this is about
91.2 GB/hour, so use a proven local SSD and plan retention explicitly. See
[`../docs/CONTINUOUS_RECORDING.md`](../docs/CONTINUOUS_RECORDING.md).

The headless `--write-service-profile` command writes only an AutoMix Native profile:
a one-to-one Dante input map plus starter service source roles. It does not change the
HD96 console, Dante Controller, or DVS configuration. It uses `--output-uid` when
supplied, otherwise a livestream-safe auto-detected output. It does not fall back to
the Dante input UID; if no stream/encoder/virtual/capture/Aggregate output is visible,
the command fails with a clear output-selection error.

Headless validation commands load the saved profile's Dante input assignments, source
roles, and complete manual processing overrides, then apply those overrides to the
running bridge before soundcheck or stability evidence is captured.

Use the Channel Map `Service Roles` button to seed a starter church role layout. It
updates names/source roles and seeds adjacent linked keys, overhead, and playback
pairs; Dante input assignments and all manual processing overrides are preserved for
each mixer row. A stereo link is valid only for adjacent, same-role music channels.
Linked automation and gate/compressor detection follow the louder side without
collapsing the independent L/R audio; manual overrides remain authoritative.

Hardware-free simulated HD96/Dante validation:

```bash
"$APP" --smoke-test --simulate-audio
file "$TMPDIR/automix-native-sim.wav"
file "$TMPDIR/automix-native-sim-soundcheck.json"
"$APP" --smoke-test --simulate-stability
file "$TMPDIR/automix-native-sim-stability.json"
"$APP" --smoke-test --verify-realtime-no-allocation
```

The simulation exposes a clearly named `Simulated HD96 Dante Split` device, starts the
same bridge/engine path at 64 channels and 96 kHz, updates input meters, runs
SAFE/FREEZE-capable `BrainThread` control, applies the sermon scene and a channel-1
manual channel-processing override through the native bridge, enables FREEZE and SAFE bypass
before the test recording, reports callback frame/dropout, callback-overrun,
render-deadline-miss, output-underrun, and output-overrun counters, and writes a
66-channel IEEE-float WAV: 64 raw inputs plus stereo stream mix, with a JSON
soundcheck report that scans the saved payload for per-input recorded peaks, active
input channel numbers, and stream L/R activity. The simulated stability smoke runs the
separate-output path, waits for active stream L/R, then measures for 30 seconds
and writes a non-recording JSON report for duration, sample rate, channel count, Core
Audio float-format readiness, one-to-one Dante input-map coverage, callbacks,
callback frame-size bounds, input activity, dropouts, callback overruns, render
deadline misses, output underruns/overruns, watchdog SAFE state, stream L/R level
range, momentary LUFS range, limiter gain reduction, and validation source. Simulated reports
are labeled `simulated-hd96-dante`; on-rig reports should be labeled
`core-audio-device`. The XCTest target exercises the same simulated bridge path, the
simulated separate-output route, debug no-allocation probes around both the native
simulated render path and the real Core Audio `AudioBufferList` input render path
after prepare, the generated WAV header and signal payload,
and the report pass/fail checks, including watchdog-forced SAFE state.
The headless `--verify-realtime-no-allocation` command runs those debug allocation
guards outside XCTest for the simulated render path, a single 64-channel Core Audio
input buffer, and 64 mono Core Audio input buffers. XCTest additionally drives active
soundcheck recording and the oversized Core Audio input callback path through the same
guard, proving that capture stays allocation-free and the fail-closed overrun branch
is silent and allocation-free. The headless guard is
intentionally DEBUG-only because Release builds do not install the allocation-counting
guard. XCTest also forces rapid continuous-recording rotation, verifies every
segment's float-WAV metadata and raw-input/program activity, checks exact aggregate
frame accounting with zero recorder drops, and runs the Core Audio input allocation
guard while continuous capture is armed.

## First-light rehearsal (Dante + 24 channels, rig not fully configured yet)

The live broadcast Start enforces strict gates (96 kHz, output isolated from FOH/Dante,
full 1:1 channel coverage, source roles). For a first rehearsal those gates will stop
you on purpose. Flip the **Rehearsal** switch in the top bar to relax the *policy* gates
so you can verify signal flow. Rehearsal still enforces the *technical* requirements the
audio path needs: a real input, a separate output, 32-bit float format, and a matched
input/output clock. **Rehearsal is not broadcast-safe** — the running state says so, and
soundcheck/stability proof will still fail (they require 96 kHz + isolation), so a
rehearsal run can never masquerade as hardware proof.

Steps for tomorrow:

1. Start Dante Virtual Soundcard; confirm macOS shows it as a Core Audio input. Note its
   **sample rate** in Dante Controller / the DVS panel (commonly 48 kHz).
2. Pick a **separate output device at the same sample rate as DVS.** This is the one real
   gotcha: the engine does not resample, so input and output rates must match. Easiest:
   open *Audio MIDI Setup* and set your output (e.g. MacBook Pro Speakers, BlackHole, or
   an Aggregate that does **not** contain DVS) to DVS's rate. Do **not** pick the Dante
   device as the output — the mix must not go back into Dante.
3. In AutoMix Native: turn **Rehearsal** on, select the Dante input + that output, grant
   mic permission if asked, then **Start (Rehearsal)**. Rehearsal auto-sizes the channel
   map + expected count to whatever DVS exposes and seeds starter roles.
4. Speak/play into your patched channels and watch the per-channel meters move on the
   matching rows, plus the Stream Mix L/R meters. Open the remote console on your phone
   to watch the same thing from the room.
5. When the rig is fully on a 96 kHz clock and you have an isolated stream output, turn
   Rehearsal **off** and use the strict path + the Hardware validation checklist below
   for real broadcast proof.

If Start (Rehearsal) still refuses, the message names the blocking technical check —
almost always an input/output **sample-rate mismatch** (fix the output rate in Audio MIDI
Setup) or a missing/`<2`-channel output.

## Remote operator console (same-Wi-Fi)

For services run with no operator in the room, the app hosts an embedded web console
so a phone/tablet on the same Wi-Fi can monitor the mix, get alerted when something
needs attention, and intervene. It is a dependency-free Swift server (Network.framework,
SSE down / POST up) serving an installable PWA. It never touches the audio thread; it
reads already-published meters/counters and issues control-rate changes through the
same paths the desktop buttons use.

- Turn it on in the desktop app's `Remote Monitoring` panel (on by default). The panel
  shows the `http://<mac>.local:8420` URL, a QR code, a 6-digit pairing code, the
  connected/paired client count, and a `Revoke all` button. macOS may ask to allow
  incoming network connections the first time.
- On the phone: open the URL, watch live stream meters, LUFS, limiter GR, per-channel
  input levels, scene, and health. Enter the pairing code once to unlock control:
  engage/release SAFE, mute or fader/pan-override individual channels, and change
  scenes. Monitoring is view-open; control requires a paired, HttpOnly browser cookie,
  so a stray device on the network cannot act. The cookie is never exposed to
  JavaScript or persistent browser storage.
- Remote mutation stays locked until the phone has observed two advancing telemetry
  timestamps. An SSE error, malformed snapshot, non-advancing timestamp for 1.5
  seconds, offline event, background-resume with stale data, or unacknowledged command
  disables every scene, channel, and SAFE control and leaves a persistent
  **Remote controls locked** banner. Search, filters, and channel-detail inspection
  remain available because they do not change the mix.
- Every command is bound to the snapshot timestamp the operator saw. The Mac rejects
  missing/future/stale client state with HTTP 409, rejects a stale producer with 503,
  and returns 504 if the main-actor control path does not acknowledge within one
  second. A monotonic execution clock expires work that waits more than 750 ms for
  the main actor before routing, so a timed-out command cannot mutate the mix later.
  The phone shows command success/failure instead of swallowing it. SAFE engagement
  remains one action; SAFE release requires the existing two-step UI plus an explicit
  server-side confirmation marker. FREEZE is deliberately local-only.
- Add to Home Screen to install the PWA; a critical fault (stream silent, watchdog
  SAFE, engine stopped, …) flashes the screen red, sounds an alarm, and fires a Web
  Notification. Alert conditions are computed authoritatively on the Mac
  (`AlertEvaluator`) and pushed in the telemetry; the phone only reacts.
- "Mute" from the console is a fader override at the -80 dB floor (no DSP/bridge
  change), and unmute restores the prior fader state.
- The embedded console intentionally uses HTTP for direct same-LAN access. Put it on
  an isolated, trusted production/management network; it is not safe to expose to
  guest Wi-Fi or the public internet. Service-worker installation and Web
  Notifications may be unavailable when the browser requires a secure HTTPS context;
  the live browser console and alarm remain the supported baseline.

Headless end-to-end check (no phone, no rig): starts the server on an ephemeral
loopback port with a canned snapshot and exercises static serving, `/health`, auth
gating, pairing, snapshot-bound commands, stale producer/client rejection, SAFE
release confirmation, bounded command timeout, and the SSE stream. The browser-side
freshness state machine also has dependency-free Node tests.

```bash
"$APP" --monitor-smoke   # prints per-check status, exits 0 on pass
```

The remote console design is specified in
`docs/superpowers/specs/2026-06-20-remote-operator-console-design.md`.

## Live HD96/Dante setup

The app does not configure the Midas console. It expects Dante to already exist:

1. HD96 direct outs/splits are already published to the Dante network.
2. Dante Virtual Soundcard is running on the Mac at 96 kHz.
3. macOS sees Dante Virtual Soundcard as a Core Audio device with the expected input
   channel count.
4. The selected Core Audio input/output streams are 32-bit little-endian float PCM.
5. macOS has granted AutoMix Native audio input permission in System Settings >
   Privacy & Security > Microphone.
6. Select that device in AutoMix Native.
7. Select a separate Core Audio stream-output device, BlackHole/Loopback/OBS virtual
   route, or known-good Aggregate Device output at the same sample rate. Do not use
   the same Dante/HD96-facing route for the stream output on real hardware.

## Current behavior

- Device list reads Core Audio UID/name, input channels, output channels, nominal
  sample rate, buffer size, and input/output stream-format readiness. It also appends
  the simulated HD96/Dante validation device for no-hardware testing.
- Device selection prefers Dante-named inputs and stream/encoder/virtual/capture or
  Aggregate outputs. If no livestream-safe output is visible, the output picker stays
  unresolved instead of silently defaulting to the Dante input or built-in speakers.
  Existing output selections are revalidated after input or device-list changes, so a
  stale unsafe route is cleared or replaced with a livestream-safe target. Saved
  non-empty input UIDs are preserved when missing and shown as a route problem instead
  of being silently replaced by the simulated validation device.
- Start checks macOS audio input permission before opening Core Audio input and shows a
  direct System Settings message if permission is denied or restricted.
- Start validates selected Core Audio input/output virtual stream formats and fails
  clearly unless the callback will receive 32-bit little-endian float PCM buffers.
- Device picker labels and HD96 Preflight surface that format readiness before the
  operator starts the engine.
- HD96 Preflight gives a single route verdict and checks input selection, Dante route
  naming, 96 kHz operation, expected input channel count, stream output availability,
  Core Audio float format, and input/output clock match. The Dante route name is
  advisory so a correctly clocked Aggregate Device can still be used.
- Dante Check compares the selected/running Core Audio input channel count against the
  saved expected HD96/Dante channel count, defaulting to 64.
- While running, the app re-checks the opened Core Audio route on the control side and
  appends a status warning if sample rate, input channel count, output isolation,
  route clock, or Core Audio format no longer matches the HD96/Dante proof criteria.
- Start opens the selected Core Audio device through `AudioDeviceCreateIOProcIDWithBlock`.
  When input and output are separate devices, the input callback writes the stream mix
  into a preallocated stereo ring buffer and a second output-device callback drains it.
- Soundcheck and stability reports keep the route UID snapshot captured when the
  engine opens, then re-read the running Core Audio devices from the bridge when
  writing proof artifacts so sample-rate, channel-count, and format drift is visible
  even if the picker selection changes later.
- Output callbacks write the stream mix only to the first stereo pair. Extra mono
  buffers/channels on a multichannel Core Audio output are cleared to silence so a
  stream mix is not mirrored into unintended device outputs.
- Oversized Core Audio input callbacks are treated as fail-closed audio warnings:
  the callback-overrun/dropout counters advance, the entire output buffer is cleared
  to silence, and DSP is skipped for that callback.
- Real Core Audio starts fail closed unless input and output are both clocked at the
  HD96/Dante target of 96 kHz; simulated validation remains available without hardware.
- Real Core Audio starts also fail closed when the selected output route is not
  isolated for livestream, so lower-level bridge callers cannot open the HD96,
  Dante, or FOH-facing route as the stream output by bypassing UI preflight.
- The Core Audio callback copies input channels into preallocated buffers, updates
  atomic input and stream-output meters, applies `BrainThread` targets, runs
  `bdsp::Engine`, and writes stereo output.
- `BrainThread` publishes control-rate channel/master targets through an atomic
  sequence mailbox, so the audio callback never takes a mutex while pulling scene,
  role, SAFE, FREEZE, or manual-override changes.
- SAFE bypass and FREEZE are operator controls backed by atomics/control-thread state.
  The audio callback also applies the SAFE atomic directly, so SAFE takes effect on
  the next render even while FREEZE is holding the last control-thread targets.
- SHADOW defaults on in saved venue profiles. The brain computes and publishes the
  same activity/noise-floor/trim/fader/master candidates, but the audio path applies
  static role/scene targets plus manual overrides. The UI shows those candidates;
  autonomous stability proof explicitly turns SHADOW off.
- Stream Mix reports the limiter's fixed latency and a one-way estimate including
  Core Audio buffers, device-reported latency/safety offsets, and separate-output
  prebuffering. Saved end-to-end audio/video measurements produce an explicit
  encoder delay recommendation; use the procedure in
  [`../docs/LATENCY_AND_LIPSYNC.md`](../docs/LATENCY_AND_LIPSYNC.md).
- Scene selection feeds `BrainThread` scene targets and is saved in the venue profile.
- Source-role edits update the running control thread and are applied to engine
  routing/automix config from the audio callback with no heap allocation or locks
  after `prepare()`.
- The channel map persists a separate Dante/Core Audio input index for each mixer
  channel. Valid saved profiles are displayed and re-saved in mixer-channel order;
  app and CLI startup also order profile rows by mixer-channel index before opening
  Core Audio. The native bridge then applies that map through fixed atomic slots and
  preallocated pointer arrays, so remapping a row while running does not add locks or
  heap allocation to the audio callback. XCTest drives a controlled Core Audio render
  to prove a remapped Dante input feeds the intended mixer channel.
- Dante Check and the soundcheck report validate one-to-one input and mixer-row map
  coverage, so duplicate Dante input assignments, duplicate mixer rows, or unmapped
  detected inputs are visible before trusting the stream mix.
- Per-channel manual overrides for trim, HPF, gate, all eight EQ bands, compressor,
  fader, pan, and reverb send are saved in the venue profile and pushed to the
  running control thread when changed. SwiftUI exposes the same bounded ranges
  accepted by the native bridge. Advanced settings synchronize across a linked
  stereo pair while pan remains independent. XCTest drives controlled Core Audio
  renders to prove processing overrides affect output and that a remote fader/pan
  edit does not clear an advanced override.
- Test recording preallocates a bounded multichannel float buffer before recording,
  captures every raw Dante input in Core Audio order plus the stereo stream mix,
  hands the completed buffer to a background file queue for WAV writing, then scans
  the saved WAV payload on a background report task and saves a JSON soundcheck
  report beside the WAV with
  device, sample-rate, channel-count, captured frame count/duration, live input-activity,
  recorded WAV input-activity, per-input recorded peak levels, active recorded input
  channel numbers, recorded stream L/R activity, stream-output, output isolation,
  Core Audio float-format readiness, stream-level, route-clock, LUFS,
  limiter-gain-reduction, callback, dropout, callback-overrun,
  render-deadline-miss, output-underrun/overrun, watchdog, scene, and
  channel-map/manual-override/SAFE-bypass evidence.
- Continuous recording uses a preallocated two-second SPSC ring and a dedicated file
  queue, rotates 60-second raw-input-plus-program float WAVs, checkpoints the open
  header about once per second, exposes segment/captured/drop/capacity state, starts
  automatically when configured, gates planned capture against free space, preserves a
  minimum live reserve, and sacrifices recorder frames rather than stream continuity
  if storage falls behind. Optional retention moves cleanly completed sessions to
  Trash rather than hard-deleting them.
- The staged headless proof can keep that recorder active for the complete stability
  window. It capacity-gates the planned duration plus reserve, rechecks reserve while
  live, drains the file queue on stop, and writes a re-verifiable
  `continuous-recording-proof.json` whose segment metadata, file lengths, persisted
  frames, drop count, route, duration, and production-vs-rehearsal verdict must agree.
- Automatic Audio Recovery watches exact route readiness and callback age, retries
  with grace/verification/backoff, reapplies the live state, and resumes continuous
  capture in a new segment directory. Runtime incidents are durable JSONL. Optional
  encoder-ingest and public-egress probes require token-free exact `/health` URLs,
  bounded fresh role-specific production contracts, and live-audio provenance rather
  than treating a generic HTTP 200 as proof. Encoder health is numeric-loopback only;
  public egress rejects local observers and redirects. For OBS, the repository's authenticated
  loopback WebSocket bridge converts advancing `GetStreamStatus` encoder counters
  plus exact-input streaming-track and `InputVolumeMeters` evidence, OBS identity,
  authentication, and clean counter intervals into the encoder
  contract at
  `http://127.0.0.1:8421/health`; see
  [`../encoder/README.md`](../encoder/README.md). The public HLS observer separately
  requires a stable offsite identity/FFmpeg version, non-local playback host,
  advancing CDN sequence, and a decoded audio frame from the newest segment; deploy
  it offsite as documented in
  [`../egress/README.md`](../egress/README.md). See
  [`../docs/RUNTIME_RESILIENCE.md`](../docs/RUNTIME_RESILIENCE.md) for the LaunchAgent,
  session-resume contract, and kill-test procedure.
- Hardware rollout is gated sermon-first, then worship only after a verified real
  sermon manifest and a post-review, SSH-signed operator acceptance whose trusted
  identity, evidence hashes, and exact sermon-manifest hash verify. Stability proof
  supports up to four hours; the evidence runner and acceptance criteria are in
  [`../docs/STAGED_ROLLOUT.md`](../docs/STAGED_ROLLOUT.md).
- Native SHADOW runs automatically append one-second candidate snapshots containing
  the actual engine SHADOW state, route, per-channel measurements/candidate controls,
  master candidate trim, SAFE/FREEZE state, and program levels. The control-side
  JSONL writer never touches the audio callback. Signed rollout acceptance parses
  the complete file for route, continuity, activity, candidate movement, and
  non-application semantics; see
  [`../docs/SHADOW_DECISION_EVIDENCE.md`](../docs/SHADOW_DECISION_EVIDENCE.md).
- The embedded monitor server's token-free `/health` endpoint is the supported
  external primary-audio heartbeat. It fails closed with HTTP 503 for operator Stop,
  a stopped engine, non-production/simulated/wrong route, callback stall, or a
  control-loop update older than one second. An external controller must poll at
  least twice per second with a request timeout no longer than one second, treat
  unreachable/non-200/stale results as backup, latch backup, and require manual
  return; see [`../docs/EXTERNAL_FAILOVER.md`](../docs/EXTERNAL_FAILOVER.md).
- The Soundcheck controls expose each phase explicitly: recording frames, saving the
  WAV file, then analyzing the saved payload for the report.
- Stability Monitor runs a longer non-recording validation from the control side and
  saves a JSON report with elapsed duration, callback activity, callback frame-size
  bounds, dropout delta, callback-overrun delta, render-deadline-miss delta, output
  underrun/overrun delta, Watchdog SAFE state, observed input activity, Core Audio
  float-format readiness, route-clock, output isolation, one-to-one Dante
  input-map coverage, operator SAFE-bypass/FREEZE-disabled proof, stream L/R min/max
  levels, momentary LUFS range, and limiter gain reduction. Use it for separate-device
  drift checks without preallocating a huge multichannel WAV.
- The realtime callback tracks callback-frame overruns, render deadline misses, and
  separate-output underruns/overruns with atomics; the UI and validation reports show
  callback frame size, stream L/R levels, LUFS, limiter gain reduction, dropout count,
  callback overruns, render deadline misses, output underruns, and output overruns
  from the control side. Oversized input callbacks are silenced and skipped rather
  than partially rendered.
- Venue profile JSON is saved in Application Support with device UIDs, expected input
  channel count, scene, Dante-input-to-mixer-channel mapping, channel roles, and
  manual override values.

## Hardware validation checklist

Run this on the actual HD96/Dante rig before trusting it live:

1. Confirm Dante Controller shows the HD96 and Mac/DVS clocked to the same 96 kHz
   leader clock.
2. Confirm AutoMix Native has macOS audio input permission.
3. Run the no-audio device inventory with both `--input-uid` and `--output-uid`,
   then confirm it lists the selected 64-input 96 kHz input candidate plus a separate
   stream encoder/virtual stereo output candidate before opening Core Audio for
   validation.
4. Run the headless Core Audio full check. If it stops at preflight, fix the blocking
   route problem before soundcheck. Output Isolation is blocking for hardware proof;
   the output must feed only the stream encoder/virtual output path, not a Dante/HD96
   return. Non-blocking notes such as a missing Dante label on a known-good Aggregate
   Device name can be accounted for separately.
5. Confirm the selected Core Audio device reports the expected channel count in the app
   with no Dante Check warning.
6. Start AutoMix Native with SAFE enabled.
7. Speak/play into known HD96 channels and confirm each app meter moves on the matching
   channel-map row, with at least the active service channels assigned to source roles
   such as Speech, Lead Vocal, BGV, instruments, keys, drums, or playback. Confirm
   intended stereo pairs are adjacent, same-role, and labeled L/R; preflight must show
   `Stereo Links` passing.
8. Confirm Stream Mix L/R meters are active and not pinned near 0 dBFS.
9. Confirm LUFS telemetry is active and limiter gain reduction is not excessive.
10. Record a 10-second test and verify the WAV has all expected raw input channels plus
   stream L/R, captured duration is near the requested 10 seconds, input activity is
   nonzero, the report's per-input peak list matches the intended HD96 channel order,
   the generated soundcheck report passes, and
   `validationSource` is `core-audio-device`; its proof-control fields must show
   SAFE bypass enabled and Watchdog SAFE inactive.
11. Route app stereo output to the stream encoder, not back to FOH.
12. Toggle FREEZE and SAFE while audio is passing and confirm no stream silence.
13. Stop/restart the engine and confirm the app reports sample-rate/device errors clearly
   if DVS is stopped or clocked wrong.
14. If using separate input/output devices, confirm the full-check Stability Monitor
   report covers the desired hold time and passes with callback-overrun,
   render-deadline-miss, output-underrun, and output-overrun deltas at 0; if
   it fails, use an Aggregate Device or shared-clock route. Confirm its
   `validationSource` is `core-audio-device` and its proof-control fields show
   operator SAFE bypass and FREEZE disabled.
15. Confirm the full-check manifest has `hardwareProofPassed=true`; a simulated
   manifest can have `passed=true` but is still not hardware proof.
16. Confirm Watchdog SAFE remains inactive during normal audio; if it becomes active,
    treat that as a control-thread failure and do not go live until it is understood.
17. Use `scripts/run-staged-hardware-proof.sh` for acceptance evidence. It refuses
    development/ad-hoc builds and records signature, notarization, Gatekeeper, and
    executable-hash evidence before the run. Production mode also requires a fresh
    `scripts/audit-production-host-readiness.py` report, rechecks its live state and
    file hashes, binds it to the requested phase/route/profile/recording volume, and
    verifies at least two hours of continuous 64-input-plus-program recording.
    Shorter `REHEARSAL_ONLY=1` runs cannot mint production proof. After reviewing a
    production run, use `scripts/record-proof-acceptance.sh`; the worship gate accepts
    only an approved sermon bundle that passes `scripts/verify-proof-acceptance.sh`
    against the venue's trusted-signer file.

The current app has been build-verified locally, XCTest-verified through the simulated
native bridge, and DSP-verified without hardware. Real Dante clocking, channel order,
separate-device drift, and long-run dropout behavior still need the HD96 rig.
