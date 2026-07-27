# Live DAW — Autonomous Church Broadcast Mixer

Two things live in this repo:

1. **[`SPEC.md`](SPEC.md)** — the full build spec for the shippable product: a
   plugin-free C++/JUCE appliance that takes a Dante split and autonomously builds a
   broadcast mix, with a human override layer. That's the months-long engineering
   target.

2. **[`native/`](native/)** — the native Apple Silicon macOS app target. It is a
   SwiftUI/Core Audio shell around the existing C++ DSP and brain code. This is the
   production direction for an M-series Mac running Dante Virtual Soundcard with a
   Midas Heritage-D HD96-24 Dante split.

3. **[`web/`](web/)** — a **runnable proof-of-concept** of the entire architecture,
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

### Run the proof-of-concept

```bash
cd web
npm install
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
  while preserving Dante input routing and manual overrides;
- shows live stream L/R output meters so silence or clipping is visible before the
  encoder is trusted;
- shows master momentary/short-term/integrated LUFS and limiter gain reduction for
  livestream loudness sanity checks;
- saves a local venue profile with Core Audio device UIDs, expected channel count,
  scene, Dante input mapping, channel roles, and per-channel manual fader/pan
  overrides covering the native engine range of -80 to +12 dB fader and full
  left/right pan;
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
  manual fader/pan override coverage, SAFE-bypass proof state, opened-route identity, active
  non-clipping stream L/R levels, LUFS telemetry, and limiter gain reduction; proof
  reports preserve opened-route UID identity while re-reading running Core Audio
  sample-rate, channel-count, and format properties when the report is written;
- enforces SAFE bypass directly from the audio callback so the next render enters the
  safe static mix even while FREEZE is holding control-thread targets;
- includes a non-recording stability monitor for longer HD96/Dante runs, producing a
  JSON report for dropout deltas, callback-overrun deltas, render-deadline-miss
  deltas, output-underrun/overrun deltas, watchdog SAFE state, callback activity,
  callback frame-size bounds, observed input activity, Core Audio
  float-format readiness, route clocking, output isolation, one-to-one Dante input-map coverage,
  manual fader/pan override coverage, operator SAFE/FREEZE proof-control state,
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
measurement-driven activity/noise-floor/gain decisions, manual override guards, and
the no-heap-allocation invariant for `Engine::process`, measurement publication,
and live channel config updates.

Native XCTest coverage for the simulated Core Audio bridge:

```bash
xcodebuild test -project native/AutoMixNative.xcodeproj \
  -scheme AutoMixNative \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  CODE_SIGNING_ALLOWED=NO
```

This launches the native test host, starts the simulated 64-channel / 96 kHz
HD96/Dante bridge, checks meters/realtime counters/role/manual controls, verifies native
manual fader/pan override set/clear behavior in controlled Core Audio renders, verifies native
FREEZE and SAFE bypass still produce stereo stream output, verifies expected channel-count
warning/profile behavior, exercises simulated separate-output routing, records a
test WAV, runs debug no-allocation probes across the native simulated render path
and the real Core Audio `AudioBufferList` input render path, verifies the WAV header,
frame count, duration, and checks soundcheck report
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
validation also applies saved manual fader/pan overrides before soundcheck and
stability runs, so the generated proof reports describe the mix state that was
actually rendered.

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
output UIDs to match the manifest route, verifies the exact same channel map, source
roles, and manual override values appear in preflight, soundcheck, and stability
proofs, and exits nonzero for simulated validation, dummy artifacts, profile-map
mismatches, or incomplete hardware proof.
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

The scene timeline can run off your **actual** Planning Center Services plan instead of
the built-in sample. It uses a **Personal Access Token** kept server-side — it never
enters the browser bundle, and the browser only calls the same-origin `/pco` dev proxy
(which also avoids CORS). In the shipping appliance the device makes these calls itself.

1. Create a token at <https://api.planningcenteronline.com/oauth/applications> →
   *Personal Access Tokens*.
2. `cp web/.env.example web/.env` and fill in `PCO_APP_ID` / `PCO_SECRET` (optionally pin
   `VITE_PCO_SERVICE_TYPE_ID`). Restart `npm run dev`.
3. In the app, click **Connect Planning Center** in the scene bar — it pulls your next
   (or most recent) plan and maps each item to a scene (songs → Worship; message /
   prayer / welcome → speech-forward scenes; pre/post → ambient). Mapping lives in
   `web/src/scenes/pco.ts`.

No credentials handy? Click **sample** to run the exact same parser + scene-mapping on a
bundled PCO-shaped plan (fully offline). If a live connect fails it shows a clear error
and keeps mixing on the fallback plan — it never interrupts the program.
