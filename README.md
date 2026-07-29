# Live DAW — Autonomous Church Broadcast Mixer

Five layers live in this repo:

1. **[`SPEC.md`](SPEC.md)** — the acceptance contract for the shippable product: a
   plugin-free C++/JUCE appliance that takes a Dante split and autonomously builds a
   broadcast mix, with a human override layer.

2. **[`native/`](native/)** — the native Apple Silicon macOS app target. It is a
   SwiftUI/Core Audio shell around the existing C++ DSP and brain code. This is the
   production direction for an M-series Mac running Dante Virtual Soundcard with a
   Midas Heritage-D HD96-24 Dante split.

3. **[`appliance/`](appliance/)** — the shared deterministic C++17 DSP/control core,
   its replay evaluator and correctness suite, plus the strict headless JUCE
   portability executable.

4. **[`web/`](web/)** — a **runnable proof-of-concept** of the entire architecture,
   built with the Web Audio API. It is *not* the Dante appliance, but it is a faithful,
   working embodiment of the spec's design that you can open in a browser today:

   - **Audio thread** = `AudioWorklet` processors running real, deterministic,
     per-sample DSP with **no ML in the path**: a Dugan-style gain-sharing automixer,
     a BS.1770 / EBU-R128 loudness meter + true-peak look-ahead limiter, and a
     gate/expander.
   - **Brain thread** = a control-rate (~20 Hz) decision loop that classifies each
     channel, fits auto-EQ toward per-class target curves, rides levels to per-scene
     balance targets, and de-esses — all on the main thread, never in the audio path.
   - **Supervisory UI** = the product surface: per-channel auto-labels + confidence,
     dual pre/post metering, a live readout of *what the AI is doing and why*, manual
     override on every parameter, a global **FREEZE**, a **hard bypass to a safe mix**,
     and a Planning-Center-style **scene engine** that drives the mix from a service plan.

5. **[`failover/`](failover/)** — the independent, fail-closed external
   primary/backup supervisor. It validates the native app's heartbeat, grants only a
   short renewable primary lease, starts and stops on backup, and requires an
   explicit operator return after renewed health proof. Its strict private config
   and hardened systemd installer make the separate controller reproducible and
   fail closed until the relay confirms backup. It still requires the real
   normally-backup relay, isolated encoder inputs, and venue kill tests.

The requirement-by-requirement distinction between locally verified software and
venue-only production evidence is maintained in
[`docs/COMPLETION_AUDIT.md`](docs/COMPLETION_AUDIT.md).

### Development setup

The checked-in Xcode project builds without regeneration. CMake and XcodeGen are
declared for appliance builds and intentional project regeneration:

```bash
brew bundle
```

### Run the proof-of-concept

```bash
cd web
npm ci
npm run dev
```

Open the printed URL. Click **Start Engine**, then either:
- **Synthetic Stage** — 10 simulated church-stage channels (2 speech mics, lead vox,
  BGV, acoustic, electric, bass, kick, keys, tracks L/R) with distinct spectra so you
  can watch the classifier, auto-EQ, automix, and loudness all react. Works with zero
  audio files.
- **Microphone** — feed it your own voice and watch the speech automix, auto-EQ, and
  loudness limiter work on real audio.

Walk the **scene timeline** (Pre-Service → Worship → Sermon → Prayer → Post-Service)
to see the mix re-balance, the band duck under the sermon, and the speech automix take
over — driven by a mock service plan exactly the way Planning Center would drive it.

### How the proof maps to the spec

| Spec block | Proof-of-concept implementation |
| --- | --- |
| Two-rate split | `AudioWorklet` (audio thread) + `setInterval` brain loop (control rate) |
| Gain-sharing automixer | `public/worklets/automix-processor.js` (per-sample, on audio thread) |
| BS.1770 loudness + true-peak limiter | `public/worklets/loudness-processor.js` (K-weighting + 4× true-peak) |
| Gate / expander w/ hysteresis | `public/worklets/gate-processor.js` |
| HPF, parametric/tonal EQ, compressor, pan | native Web Audio nodes, params ramped to avoid zipper |
| Channel classifier | `src/brain/classifier.ts` (spectral-feature model, ONNX-swappable) |
| Auto-EQ toward target curves | `src/brain/autoEq.ts` + `src/brain/targets.ts` |
| Auto-levels per scene | `src/brain/brain.ts` (fader ride + scene target section) |
| Scene engine (Planning Center) | `src/scenes/*` driven by a mock plan |
| Failsafe (freeze / bypass / watchdog / rate-limit) | `src/brain/brain.ts` + transport controls |

The classifier here is a transparent spectral-feature model so the whole thing runs
with no model download; it is structured so a trained ONNX/Core ML model drops into the
same interface in the real appliance.

### Native Apple Silicon macOS app

The native app is generated with XcodeGen and builds as an arm64 macOS `.app`:

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

Current native milestone:
- lists Core Audio devices, prefers Dante-named input devices when present, and
  prefers stream/encoder/virtual/capture/Aggregate outputs instead of defaulting the
  stream output to a Dante or generic local device; selected stream outputs are
  revalidated when the input route or Core Audio device list changes, so stale unsafe
  routes are cleared or replaced with a livestream-safe target; saved non-empty input
  UIDs are preserved when missing instead of being silently replaced by simulation;
- detects input/output channel count, nominal sample rate, and buffer size;
- shows an HD96 preflight verdict for input selection, Dante route naming, 96 kHz,
  expected input channels, stream output availability, and input/output clock match;
- checks macOS audio input permission before opening Dante/Core Audio input and gives a
  direct System Settings message if permission is denied or restricted;
- warns when the selected device is not running at the HD96/Dante target of 96 kHz
  or does not match the expected HD96/Dante input channel count, and appends a running
  route warning to the status line if the opened Core Audio route later drifts on
  sample rate, channel count, stream output isolation, clock match, or format;
- opens same-device Core Audio I/O or separate Core Audio input/output devices with a
  preallocated stereo output ring buffer;
- writes stream audio only to the first stereo output pair and clears extra mono or
  interleaved multichannel output buffers/channels to silence so the stream mix is
  not mirrored into unintended device outputs;
- keeps the legacy JUCE appliance scaffold aligned with the native safety model:
  it refuses non-96 kHz devices and clears output channels beyond stereo L/R;
- validates the selected Core Audio input/output stream formats before startup so the
  callback only runs against 32-bit little-endian float PCM buffers, and surfaces that
  readiness in the device picker/HD96 preflight;
- shows a Dante/Core Audio input -> mixer channel -> source role map, with live
  meters for every mapped mixer channel;
- verifies the native bridge applies that Dante/Core Audio input map during render,
  so a remapped input feeds the intended mixer channel rather than only being saved
  in the profile;
- warns when the saved input map duplicates a Dante/Core Audio input or leaves a
  detected input unmapped;
- blocks HD96 readiness when the selected stream output is not identified as a
  stream encoder, virtual output, capture device, or known-good Aggregate Device;
  generic local outputs such as built-in speakers do not count as hardware-proof
  livestream routes;
- blocks the native Start action before opening Core Audio when route-safety checks
  fail, including same-Dante output routes, sample-rate/channel-count mismatches,
  unsupported Core Audio formats, route clock problems, or duplicate/missing Dante
  input-map assignments, and the Core Audio bridge itself refuses real device starts
  unless input/output are clocked at 96 kHz and the output route is isolated for the
  livestream instead of pointing back at an HD96/Dante/FOH route;
- blocks HD96 preflight when the saved map has duplicate/missing Dante inputs,
  duplicate/missing mixer rows, or out-of-range assignments; app and CLI startup
  order valid profile rows by mixer-channel index before opening Core Audio, and
  the UI displays/re-saves valid profiles in that same order;
- blocks HD96 preflight and validation reports when the saved profile has no assigned
  source roles for the autonomous mixer;
- includes a Channel Map `Service Roles` command to seed a starter church role layout
  covering speech, vocals, guitars, bass, kick, snare, toms, overheads, percussion,
  keys, and playback while preserving Dante input routing and manual overrides;
- persists adjacent stereo pairs and validates that they are same-role,
  non-overlapping music sources; the C++ engine links their gate/compressor detectors,
  shares conservative automation targets, and keeps their audio hard-panned L/R;
- shows live stream L/R output meters so silence or clipping is visible before the
  encoder is trusted;
- shows master momentary/short-term/integrated LUFS and limiter gain reduction for
  livestream loudness sanity checks;
- reports exact DSP latency plus a Core Audio one-way estimate that includes device
  buffers, device latency/safety offsets, and separate-output prebuffering; the venue
  profile stores measured end-to-end audio/video paths and tells the operator which
  encoder path needs delay;
- saves a local venue profile with Core Audio device UIDs, expected channel count,
  scene, Dante input mapping, channel roles, and complete per-channel manual
  overrides for trim, HPF, gate, eight-band EQ, compressor, fader, pan, and reverb
  send; every family uses the same bounded ranges as the native engine;
- pushes source-role edits to the running control thread and applies the matching
  engine routing/automix config on the audio callback without heap allocation or locks;
- publishes per-channel input RMS/peak and post-strip RMS from the audio callback to
  the control-rate brain through atomic mailboxes; assigned roles use those
  measurements for activity detection, idle-only noise-floor learning, bounded
  digital gain staging, adaptive gate thresholds, and conservative level riding,
  while unassigned channels remain untouched by automatic gain changes;
- ramps automatic scene and level changes instead of stepping them, with a full
  sermon-scene move settling in roughly 1–2 seconds and persisted manual overrides
  retaining final authority;
- defaults the operator app to SHADOW mode: the native brain continues learning and
  exposes per-channel activity/noise-floor/trim/fader plus master-loudness
  candidates, while the audible path holds static role/scene settings and manual
  overrides; autonomous stability proof explicitly disables SHADOW;
- closes the native master loudness loop only after a complete three-second
  short-term measurement: correction is bounded to ±6 dB, moves no faster than
  1 dB/second, ignores silence, holds during FREEZE/SAFE, and backs away instead of
  adding gain when the true-peak limiter is already working;
- uses block-duration-correct detector timing in the speech gain-sharing automixer,
  with behavior tests for first-talker acquisition and talker handoff at the native
  96 kHz operating point;
- exposes SAFE bypass, FREEZE, and a 10-second soundcheck WAV containing every Dante
  input in raw Core Audio/Dante order plus the stereo stream mix, independent of the
  editable mixer input map, with a background-generated JSON soundcheck report
  that also verifies live input activity, recorded WAV input activity, recorded stream
  L/R activity, per-input recorded peak levels/active channel numbers, stream output
  channels, captured frame count/duration, Core Audio float-format readiness, route
  clocking, output isolation, one-to-one Dante input and mixer-row map coverage,
  complete manual-processing override coverage, SAFE-bypass proof state,
  opened-route identity, active
  non-clipping stream L/R levels, LUFS telemetry, and limiter gain reduction; proof
  reports preserve opened-route UID identity while re-reading running Core Audio
  sample-rate, channel-count, and format properties when the report is written;
- continuously records raw Core Audio/Dante inputs plus final stream L/R into
  checkpointed 60-second float-WAV segments on a dedicated file queue; a preallocated
  two-second SPSC ring keeps all file I/O off the audio callback, recording pressure
  drops and counts recorder frames instead of blocking the mix; the native app can
  start capture with the engine, gates start on planned-duration capacity plus a free
  reserve, rechecks capacity while live, and supports opt-in retention that moves only
  cleanly completed sessions to Trash; the operator UI exposes storage state, captured
  frames, segment count, output folder, and drop telemetry; storage sizing, archival,
  and recovery limits are documented in
  [`docs/CONTINUOUS_RECORDING.md`](docs/CONTINUOUS_RECORDING.md);
- detects route loss and callback stalls, retries the exact configured route with
  verification and bounded backoff, restores continuous-capture intent, and writes
  ordered durable incident JSONL; optional encoder-ingest and public-egress endpoints
  provide fresh, exact-role, production-eligible payload verification to the desktop,
  remote alert, staged-proof, and signed-acceptance paths; proof rejects an egress
  peer bound to the production Mac and preserves the actual local/remote peer plus
  stable observer/software identity and role-specific
  encoder/HLS progression evidence, with the
  dependency-free authenticated OBS WebSocket bridge exposing exact stream and
  program-audio-carrier state at a loopback encoder-health endpoint (see
  [`encoder/README.md`](encoder/README.md)), and the independently deployable HLS
  observer proving advancing, downloadable, decodable public CDN audio (see
  [`egress/README.md`](egress/README.md)); the
  embedded monitor server also serving a fail-closed `/health` primary-audio
  heartbeat for an external relay/controller (HTTP 200 only for the exact real
  64-channel/96 kHz HD96/Dante route and fresh callbacks/control loop; otherwise
  503; backup selection remains latched/manual-return hardware); remote mutations
  also fail closed unless the phone has advancing telemetry and sends the recent
  snapshot timestamp it displayed, with stale/missing state rejected and every
  control acknowledgement bounded to one second while late queued work expires
  before it can mutate the mix; the
  crash-relaunch/session-resume procedure is documented in
  [`docs/RUNTIME_RESILIENCE.md`](docs/RUNTIME_RESILIENCE.md); staged promotion
  preserves and re-verifies continuous dual-probe coverage using
  [`docs/STREAM_HEALTH_EVIDENCE.md`](docs/STREAM_HEALTH_EVIDENCE.md) and binds a
  clean, manifest-duration incident snapshot using
  [`docs/RUNTIME_INCIDENT_EVIDENCE.md`](docs/RUNTIME_INCIDENT_EVIDENCE.md);
- supports a gated sermon-first then worship hardware rollout with multi-hour
  stability windows, manifest verification, and named human acceptance before the
  worship proof; see [`docs/STAGED_ROLLOUT.md`](docs/STAGED_ROLLOUT.md);
- enforces SAFE bypass directly from the audio callback so the next render enters the
  curated role-aware raw-input mix even while FREEZE is holding control-thread
  targets; the fallback gives speech priority, attenuates instruments/unknown patch
  points, energy-normalizes the configured channel set, and still terminates in the
  true-peak limiter;
- includes a non-recording stability monitor for longer HD96/Dante runs, producing a
  JSON report for dropout deltas, callback-overrun deltas, render-deadline-miss
  deltas, output-underrun/overrun deltas, watchdog SAFE state, callback activity,
  callback frame-size bounds, observed input activity, Core Audio
  float-format readiness, route clocking, output isolation, one-to-one Dante
  input-map coverage,
  complete manual-processing override coverage, operator SAFE/FREEZE proof-control state,
  opened-route identity, stream L/R min/max levels, momentary LUFS range,
  and limiter gain reduction without buffering multichannel audio; the proof window starts after stream L/R is active or
  after a short timeout so startup silence does not pollute an otherwise healthy run;
- treats oversized Core Audio input callbacks as fail-closed audio warnings by
  counting the callback overrun/dropout, zeroing the full output buffer, and skipping
  DSP for that callback;
- keeps soundcheck capture realtime-safe by filling a preallocated memory buffer in
  the audio callback and moving WAV serialization to a non-audio file queue after the
  capture completes;
- uses the existing deterministic C++ DSP engine and control-rate `BrainThread`.

The app intentionally does not change HD96 console configuration. The expected live
setup is still: HD96 direct outs/splits already present on Dante, Dante Virtual
Soundcard on the Mac, and this app receiving those channels through Core Audio.
App/Mac/power failure requires the independent, fail-safe hardware path and kill-test
contract in [`docs/EXTERNAL_FAILOVER.md`](docs/EXTERNAL_FAILOVER.md); the in-app SAFE
button cannot cover loss of its own host.
End-to-end A/V calibration and clock-drift proof follow
[`docs/LATENCY_AND_LIPSYNC.md`](docs/LATENCY_AND_LIPSYNC.md).
The five external review artifacts use the hash-closed, manifest/commit-bound JSON
contract in
[`docs/PRODUCTION_EVIDENCE_FORMAT.md`](docs/PRODUCTION_EVIDENCE_FORMAT.md); both
acceptance recording and later verification re-run its semantic gates. The same
document includes fail-closed draft generation and automatic finalization so venue
operators do not hand-calculate attachment hashes. The fifth report makes a full
SHADOW rehearsal, supervised live service, and reviewed real Planning Center cue
trace explicit prerequisites for signed promotion. The verifier parses the native
plan-loaded and scene-applied JSONL events. Native SHADOW also produces its own
one-second 64-channel candidate-decision JSONL, and acceptance checks route identity,
coverage, gaps, candidate movement, SAFE/FREEZE exposure, and that automation never
reached program. An unrelated or non-empty placeholder trace cannot satisfy either
gate.

### Native/DSP verification

Pure C++ verification can run without Dante hardware:

```bash
clang++ -std=c++17 -O2 -Iappliance/dsp -Iappliance/src \
  appliance/tests/test_dsp.cpp \
  -o /tmp/live-daw-test-dsp
/tmp/live-daw-test-dsp
```

This covers DSP primitives, full-engine SAFE bypass, 96 kHz engine processing,
bus/pan routing, block-timed speech automixing, live source-role reassignment,
measurement-driven activity/noise-floor/gain decisions, bounded slow master
loudness normalization, stereo-linked dynamics/control behavior, manual override
guards, and the no-heap-allocation
invariant for `Engine::process`, measurement publication, and live channel config
updates.

Recorded-service replay uses the exact same C++ engine and brain with a
frame-driven, deterministic 20 Hz control clock:

```bash
clang++ -std=c++17 -O2 \
  -Iappliance/dsp -Iappliance/src -Iappliance/tools \
  appliance/tools/replay_eval.cpp \
  -o /tmp/automix-replay
/tmp/automix-replay --self-test
```

The evaluator accepts PCM/float multichannel WAVs, optionally with a final stereo
human/reference mix, and writes a rendered program WAV, safety/reference metrics
JSON, and per-control-tick decision JSONL. See
[`docs/REPLAY_EVALUATION.md`](docs/REPLAY_EVALUATION.md) for the input contract and
shadow-mode promotion gate.

Native XCTest coverage for the simulated Core Audio bridge:

```bash
xcodebuild test -project native/AutoMixNative.xcodeproj \
  -scheme AutoMixNative \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  CODE_SIGNING_ALLOWED=NO
```

This launches the native test host, starts the simulated 64-channel / 96 kHz
HD96/Dante bridge, checks meters/realtime counters/role/manual controls, verifies
native full-processing override behavior and mix-only edits in controlled Core Audio
renders, verifies native FREEZE and SAFE bypass still produce stereo stream output,
verifies expected channel-count
warning/profile behavior, exercises simulated separate-output routing, records a
test WAV, runs debug no-allocation probes across the native simulated render path
and the real Core Audio `AudioBufferList` input render path, forces rapid continuous
recording rotation while that guard is active, verifies each segment's raw-input plus
program payload and WAV metadata, verifies the soundcheck WAV header, frame count,
duration, and checks soundcheck report
readiness logic including per-channel recorded input peaks, recorded input/stream
activity, recording channel count, and watchdog-forced SAFE state.

The built app also has a headless launch/device-enumeration smoke mode:

```bash
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/AutoMix Native.app/Contents/MacOS/AutoMix Native" -print -quit)
"$APP" --smoke-test
```

On the real HD96/Dante rig, use the listed Core Audio UIDs to produce hardware-proof
reports. First write a no-audio device inventory so the selected HD96/Dante input and
stream output can be checked before opening Core Audio. The recommended proof path is
then the one-shot full check, which runs preflight, SAFE soundcheck recording, and the
longer stability monitor, then writes a manifest pointing to the inventory, preflight,
soundcheck, and stability proof files:

```bash
"$APP" --smoke-test --write-service-profile \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --scene worship \
  --profile "$HOME/Desktop/AutoMix-HD96-Proof/VenueProfile.json"

"$APP" --smoke-test --write-device-inventory \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"

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
```

The service-profile command only seeds the app profile with a one-to-one Dante input
map and starter church source roles. It does not configure the HD96 console. Headless
validation and service-profile commands use `--output-uid` when supplied, otherwise
the saved profile output, otherwise a livestream-safe auto-detected output. They do
not fall back to the Dante input UID; if no stream/encoder/virtual/capture/Aggregate
output is visible, the command fails with a clear output-selection error. Headless
validation also applies every saved manual processing override before soundcheck and
stability runs, so the generated proof reports describe the mix state that was
actually rendered. A rejected override now stops startup or headless proof capture
instead of silently falling back to autonomous settings. A rejection during a live
operator edit keeps program audio running but raises a critical visible error and
durable incident with the exact mixer channel. The alert remains latched until every
channel control applies successfully on a later retry, which is also journaled.

The individual steps can still be run separately when isolating a route, recording,
or dropout problem:

```bash
"$APP" --smoke-test --core-audio-preflight \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"

"$APP" --smoke-test --core-audio-soundcheck \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"

"$APP" --smoke-test --core-audio-stability \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --stability-seconds 300 \
  --output-dir "$HOME/Desktop/AutoMix-HD96-Proof"
```

The preflight report checks the selected route without opening the audio engine. Direct
soundcheck and stability commands also run that preflight first and stop before opening
Core Audio if the route is not ready. The one-shot full-check command writes its own
inventory, stores that path in the final manifest, runs the semantic verifier, and
exits nonzero unless the run is real hardware proof. The soundcheck and stability
reports, and the full-check manifest, must pass with `validationSource=core-audio-device`
and `hardwareProofPassed=true` before the rig is treated as hardware-proven.
The `--verify-full-check` command re-runs the same final gate for an existing manifest:
it checks that each referenced proof artifact exists and is non-empty, parses the
inventory, preflight, soundcheck report, stability report, and WAV metadata,
cross-checks them against the manifest, requires the inventory's selected input and
output UIDs to match the manifest route, derives production candidates from the
inventory's device identities instead of trusting its summary arrays, and requires
the manifest validation source to match the selected route identity. Simulated
devices remain visible as rehearsal candidates but are explicitly excluded from
production-ready counts. The verifier also checks that the exact same channel map,
source roles, and manual override values appear in preflight, soundcheck, and
stability proofs, and exits nonzero for simulated validation, relabeled simulated
routes, missing or inconsistent production inventory fields, dummy artifacts,
profile-map mismatches, or incomplete hardware proof.

Before starting the two-hour staged runner, use
[`scripts/audit-production-host-readiness.py`](scripts/audit-production-host-readiness.py)
with the freshly generated inventory/preflight, notarized app, reviewed venue
profile, matching release `build-metadata.json`, and intended recording volume. It
checks the whole production Mac at once: published source; the signature-sealed
in-app provenance, release metadata, and exact executable hash; notarization; real
selected route; fresh preflight; recording capacity; Planning Center Keychain item;
crash relaunch; a fresh exact-package readiness handoff from the separately powered
failover controller with relay-confirmed backup; OBS installation and exact-input
health; plus the remote public-egress observer. The owner-only JSON report cannot be
mistaken for final acceptance and must return
`readyForHardwareProofRun=true` before the staged runner begins. Production staged
runs require `HOST_READINESS_REPORT`, re-run the live audit, and bind its fresh
hashes to the exact phase/app/release metadata/profile/route/recording volume and
preserve the controller handoff beside it. See
[`docs/PRODUCTION_HOST_READINESS.md`](docs/PRODUCTION_HOST_READINESS.md).

For real hardware, Output Isolation is a blocking check: use a stream encoder,
BlackHole, Loopback, OBS/virtual output, or known-good Aggregate Device output, not
the same Dante/HD96-facing Core Audio route used for the input split.
The native UI can also save a proof manifest after a UI soundcheck and Stability
Monitor run; it writes and links the same no-audio device inventory plus wrapped
preflight proof artifact before saving the manifest, then runs the same semantic
verifier before showing proof status. Changing the route, scene, expected channel
count, or input map clears that stale proof evidence.

When Dante hardware is not available, run the simulated HD96/Dante validation path:

```bash
"$APP" --smoke-test --simulate-audio
file "$TMPDIR/automix-native-sim.wav"
file "$TMPDIR/automix-native-sim-soundcheck.json"
```

That starts the same native bridge in simulated mode at 64 input channels / 96 kHz,
drives the C++ engine and `BrainThread`, applies the sermon scene plus channel-1
role/manual overrides through the native bridge, enables FREEZE and SAFE bypass,
prints live meter values, and writes a 66-channel IEEE-float WAV in the temp
directory: 64 raw input channels followed by the stereo stream mix, plus a
soundcheck JSON report. It also scans the saved WAV payload to prove per-input
recorded peaks, active input channel numbers, and stream L/R activity,
prints callback frame counts and the realtime dropout, callback-overrun,
render-deadline-miss, output-underrun, and output-overrun counters; the simulated
path should report those counters at `0`, watchdog SAFE inactive, and `passed=true`.

For a non-recording drift/dropout proof that matches the Stability Monitor UI, run
the 30-second simulated stability smoke:

```bash
"$APP" --smoke-test --simulate-stability
file "$TMPDIR/automix-native-sim-stability.json"
```

That waits for active stream L/R before measuring, then writes a JSON stability report
covering duration, sample rate, channel count, Core Audio float-format readiness,
one-to-one Dante input-map coverage, callback activity, callback frame-size bounds,
input activity, dropouts, callback overruns, render deadline misses, output
underruns/overruns, watchdog SAFE state, stream L/R level range, momentary LUFS
range, limiter gain reduction, and validation source.
Simulated report JSON is labeled `simulated-hd96-dante`; the actual HD96/Dante rig
must produce `core-audio-device` reports and a full-check manifest with
`hardwareProofPassed=true` before this is treated as hardware-proven.

For a direct DEBUG-build realtime allocation guard outside XCTest, run:

```bash
"$APP" --smoke-test --verify-realtime-no-allocation
```

That checks the simulated render path, a single 64-channel Core Audio input buffer,
and 64 mono Core Audio input buffers after engine prepare. XCTest also runs the
active soundcheck recording callback and the oversized Core Audio input callback path
under the same allocation guard to prove capture and fail-closed overrun handling stay
realtime-safe.

### Planning Center (driving scenes from the real service plan)

AutoMix Native can run the scene timeline from the next (or most recent) real Planning
Center Services plan. The native app makes the API calls itself; the Personal Access
Token secret is stored in macOS Keychain and is not written to the venue profile,
incident log, or browser bundle.

1. Create a token at <https://api.planningcenteronline.com/oauth/applications> →
   *Personal Access Tokens*.
2. In **Planning Center Scenes**, enter the application ID and secret, optionally enter
   the numeric service-type ID, and select **Save Credentials**.
3. Review the recognized cues, test **Previous** / **Next**, then enable **Follow timed
   plan cues**. Timed cues use Planning Center `ItemTime.live_start_at`; pre/post
   `service_position` wins over title matching.

The plan refreshes every five minutes. A failed refresh records a warning and retries
without changing the current scene or interrupting audio. Manual scene selection,
SAFE, FREEZE, SHADOW, and channel overrides remain available. See
[`docs/PLANNING_CENTER.md`](docs/PLANNING_CENTER.md) for mapping and rehearsal steps.
Successful refreshes and cue applications record non-secret plan/cue metadata in the
runtime incident journal for the supervised rollout evidence gate.

The browser prototype still supports its same-origin `/pco` development proxy through
`web/.env`; it is not the credential path used by AutoMix Native.
