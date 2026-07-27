# Autonomous Church Broadcast Mixer — Build Spec

## Goal
A plugin-free, self-contained software mixing engine that takes a Dante split of
raw input channels, builds a fully independent broadcast/livestream mix
autonomously (gates, EQ, dynamics, automix, levels, loudness), and outputs to the
stream encoder. It never touches FOH. A human can override anything.
Target: native Apple Silicon macOS `.app` on an M-series Mac.

## Current native macOS target
- Production app: `native/AutoMixNative.xcodeproj`, generated from
  `native/project.yml` with XcodeGen.
- App shell: SwiftUI macOS operator UI for Core Audio device selection, HD96
  preflight, Dante check, channel mapping, meters, SAFE, FREEZE, soundcheck, and
  stability monitoring.
- Audio I/O: Objective-C++ Core Audio bridge using
  `AudioDeviceCreateIOProcIDWithBlock` against Dante Virtual Soundcard, Dante
  hardware, or an Aggregate Device exposed by macOS.
- Legacy JUCE appliance scaffold: remains a headless portability shell for the same
  C++ DSP/brain, but refuses non-96 kHz devices and clears output channels beyond
  stereo L/R so it does not mirror the stream mix into unintended routes.
- Mixer core: existing C++ `bdsp::Engine` plus `app::BrainThread`.
- Native automation foundation: the audio callback publishes per-channel input
  RMS/peak and post-strip RMS through lock-free atomic mailboxes. At 20 Hz, the brain
  learns noise floors only while idle, detects activity with hold time, applies
  bounded digital gain staging and adaptive gate thresholds to assigned source
  roles, and makes small per-scene level rides. Automatic fader targets are
  rate-limited so scene changes settle over roughly 1–2 seconds; persisted manual
  fader/pan overrides still win. Unknown roles are measured but receive no automatic
  gain correction.
- Worship/source coverage: native role profiles include speech, lead and background
  vocals, acoustic/electric guitar, bass, kick, snare, toms, overheads, percussion,
  keys, and playback/tracks. Adjacent same-role music channels can be persisted as
  stereo pairs. Linked pairs share conservative trim/ride targets and max-of-pair
  gate/compressor detectors, retain independent audio, and hard-pan L/R so a louder
  side cannot steer the stereo image. Speech, unknown, overlapping, mismatched-role,
  and non-adjacent links are rejected by preflight and proof reports.
- Native master loudness control: after the BS.1770 meter has a complete three-second
  short-term window, the brain applies a maximum 1 dB/second correction bounded to
  ±6 dB before the final loudness meter and true-peak limiter. Silence/noise cannot
  trigger upward gain, SAFE/FREEZE hold the current correction, and significant
  limiter gain reduction forces the controller to back away.
- Native shadow mode: venue profiles default to SHADOW enabled. The brain continues
  measuring and computes the same automatic trim, gate, fader, and master candidates,
  while the rendered program uses static role/scene targets plus operator overrides.
  The UI exposes candidate activity, learned floor, trim, fader, and master trim.
  Autonomous stability proof turns SHADOW off so proof cannot accidentally certify
  a static mix as autonomous.
- Latency/lip sync: the limiter exposes and impulse-tests its exact 1.5 ms delay. The
  native bridge reports a one-way estimate from input/output buffers, Core Audio
  device latency/safety offsets, DSP latency, and any separate-output prebuffer.
  Venue profiles persist measured end-to-end audio and video path latency and the UI
  names the path/delay needed for alignment. Real measurement and drift gates are in
  `docs/LATENCY_AND_LIPSYNC.md`.
- CPU/architecture: arm64-only Apple Silicon build.
- HD96/Dante operating point: 64 mapped input channels at 96 kHz, with clear
  sample-rate, channel-count, Core Audio float-format readiness, callback frame-size,
  dropout, callback-overrun, render-deadline-miss, output-underrun, and
  output-overrun status. Saved non-empty Core Audio input UIDs are preserved and
  reported missing rather than silently replaced by simulation or another route.
  While running, the control-side poll re-checks the opened Core Audio route and adds
  a status warning if sample rate, channel count, stream output isolation, route
  clock, or Core Audio format drifts out of readiness.
- Output isolation: preflight, soundcheck, and stability block hardware proof unless
  the stream output is identified as a stream encoder, virtual output, capture
  device, or known-good Aggregate Device. Generic local outputs such as built-in
  speakers do not count as hardware-proof livestream routes, and same-Dante output
  routes remain blocked so the app does not silently create a FOH return risk. Default
  device selection follows the same rule and leaves output unresolved when no
  livestream-safe target is visible, then revalidates selected output routes when the
  input route or device inventory changes so stale unsafe selections are cleared or
  replaced. The native Start action also refuses to open Core Audio when route-safety
  checks fail, including same-Dante output routes,
  sample-rate/channel-count mismatches, unsupported Core Audio formats, or route clock
  problems, and when the saved Dante input map duplicates or misses detected inputs.
  The Core Audio bridge itself also refuses real device starts unless input and output
  are both clocked at 96 kHz and the output route is isolated for the livestream
  instead of pointing back at an HD96/Dante/FOH route.
- Channel map: persisted Dante/Core Audio input index -> mixer channel -> source
  role. Defaults to 1:1 and can be edited without changing the HD96 console. Valid
  saved profiles are displayed and re-saved in mixer-channel order; app and CLI startup
  also order profile rows by mixer-channel index before opening Core Audio. Preflight,
  soundcheck, and stability reports validate route clock, one-to-one Dante input and
  mixer-row map coverage, and require at least one non-unknown source role before the
  autonomous mix is treated as ready.
  Native bridge tests drive controlled Core Audio buffers to prove the map is honored
  during render, not just persisted.
  A native `Service Roles` command can seed a starter role layout, including linked
  keys, overhead, and playback pairs, without changing the Dante input map or manual
  overrides. A headless `--write-service-profile` mode can generate the same starter
  profile for rack-side validation without touching the HD96 console. Headless
  validation and service-profile commands never default the output UID to the input
  UID; they require or auto-detect a livestream-safe output.
- Manual overrides: per-channel fader/pan override values persist with the venue
  profile, expose the same -80 to +12 dB fader and full left/right pan range in
  SwiftUI that the bridge accepts, are pushed to the running control thread, and
  are included in soundcheck and stability proof checks so out-of-range saved
  overrides are visible before hardware proof is trusted. Native bridge tests
  drive controlled Core Audio buffers to prove setting and clearing fader/pan
  overrides changes the rendered stream.
  SAFE bypass is also read directly by the audio callback so it takes effect on
  the next render even while FREEZE is holding control-thread targets.
- Soundcheck: bounded multichannel WAV recording of raw Core Audio input order plus
  stereo stream L/R; the audio callback fills a preallocated memory buffer, WAV
  serialization runs later on a non-audio file queue, and a JSON report scans the
  saved payload and keeps captured frame count/duration, per-input recorded peak
  levels, active channel numbers, opened-route identity, and SAFE-bypass proof state
  for HD96 patch/order verification.
- Hardware proof: headless Core Audio validation can first write a no-audio device
  inventory for the selected DVS/Aggregate/stream-output device UIDs, then open the
  selected routes and emit `core-audio-device` reports without driving the UI. Direct
  soundcheck and stability commands run preflight before opening Core Audio, and the
  one-shot full-check mode runs preflight, SAFE soundcheck recording, and stability
  monitor, then writes and verifies a manifest tying the inventory, preflight,
  soundcheck, and stability proof files together. Stability measurement starts after active,
  non-clipping stream L/R is observed or after a short timeout, so startup silence is
  not counted as proof-window silence but a truly silent stream still fails. Soundcheck
  proof requires SAFE bypass enabled and Watchdog SAFE inactive; stability proof
  requires the normal autonomous mix path with operator SAFE bypass and FREEZE disabled.
  The native
  UI can save the same inventory/preflight-linked manifest after a manual
  soundcheck/stability run, runs the same semantic verifier before showing proof
  status, and clears stale proof evidence when proof-defining route or channel-map
  settings change. The manifest distinguishes simulated validation from real rig proof:
  `passed=true` means the selected validation path passed, while
  `hardwareProofPassed=true` additionally requires `validationSource=core-audio-device`
  and all proof artifact paths. A headless `--verify-full-check` command reads a
  manifest, verifies each referenced artifact exists and is non-empty, parses and
  cross-checks the inventory, preflight, soundcheck report, stability report, and
  WAV metadata, requires the inventory's selected input and output UIDs to match the
  manifest route, verifies the exact same channel map, source roles, and manual
  override values appear in preflight, soundcheck, and stability proofs, confirms
  proof reports retain the opened route UID identity while using running Core Audio
  route properties, requires every embedded soundcheck/stability report check to pass,
  requires the expected SAFE/FREEZE proof-control states, and exits nonzero unless the
  run is real HD96/Dante hardware proof.
- SAFE scope: operator/watchdog SAFE uses fixed source-role gains and conservative
  pans on raw inputs, normalizes the configured channel set by energy, and feeds the
  existing true-peak limiter. It does not depend on channel-strip DSP or a fresh brain
  snapshot. Full app/Mac/power failure is covered only by the independent fail-safe
  hardware/encoder topology and kill-test contract in
  `docs/EXTERNAL_FAILOVER.md`.
- ML status: no ML is shipped in the native app. Any future classifier must stay
  off the realtime callback and only publish control-rate targets.
- Offline validation: `appliance/tools/replay_eval.cpp` drives the production C++
  engine and brain from PCM/float multichannel WAVs. Its control clock advances from
  source frames rather than wall time. It writes the stereo candidate mix,
  source/config/safety/reference metrics, and a 20 Hz JSONL trace of every channel
  and master automation decision. The corpus comparison and shadow-mode promotion
  contract is defined in `docs/REPLAY_EVALUATION.md`.

Build and verification:

```bash
xcodebuild -project native/AutoMixNative.xcodeproj \
  -scheme AutoMixNative \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild test -project native/AutoMixNative.xcodeproj \
  -scheme AutoMixNative \
  -configuration Debug \
  -destination platform=macOS,arch=arm64 \
  CODE_SIGNING_ALLOWED=NO
```

## Hard constraints (do not violate)
- **No neural network in the audio path, ever.** The realtime DSP is deterministic
  C++/DSP. The current native app ships no ML; future classification, if added,
  must run at control rate on a separate thread.
- **Strict two-rate separation:** audio thread vs brain thread.
- **Manual override always wins** and freezes the brain off that parameter.
- **Failsafe/bypass exists from day one**, not bolted on later.
- **Broadcast-only.** We take a Dante split and build our own mix. FOH is untouched.

## Production stack (the appliance)
- Engine: existing C++ DSP core (`bdsp::Engine`) and control-rate
  `app::BrainThread`. JUCE remains a portability option, but the inspected native
  macOS path is a direct Core Audio bridge so the app can open Dante devices without
  a wrapper.
- Audio I/O: Dante via Dante Virtual Soundcard (Core Audio/ASIO) or hardware Dante
  interface (RME Digiface Dante / PCIe card). Target 96 kHz for the Midas
  Heritage-D HD96-24 workflow.
- ML runtime: none in the current native app. Future ONNX/Core ML work is
  control-thread-only and must not be required for the app to pass audio.
- Appliance target: Mac mini or MacBook with Apple Silicon, using macOS Core Audio.
- Integration: the native app reads Planning Center Services plans with a
  Keychain-protected Personal Access Token, maps service position/item vocabulary to
  scenes, and can follow `ItemTime.live_start_at` cues. API failure holds the current
  scene and never interrupts audio.

## Core architecture: two-rate
- **Audio thread:** per-sample deterministic DSP. No allocation, no ML, no blocking.
  All parameters smoothed/ramped. Must complete each buffer within deadline
  (128 samples @ 96 kHz = 1.33 ms).
  The C++ DSP tests guard `Engine::process` / `BrainThread::applyTo` against
  heap allocation after prepare, and the native XCTest suite runs a debug
  no-allocation probe around both the simulated Core Audio render path and the
  real Core Audio `AudioBufferList` input render path. The debug app binary also
  exposes `--verify-realtime-no-allocation` for a headless allocation-guard run.
  Oversized Core Audio input callbacks are counted as callback overruns/dropouts,
  zero the full output buffer, and skip DSP for that callback instead of partially
  rendering stale or truncated audio. XCTest covers active soundcheck recording and
  that overrun branch under the DEBUG realtime allocation guard.
- **Brain thread:** control rate, 10–50 Hz. Measurement, FFT analysis, future
  classification, and decisions. Sets target params; the audio thread ramps to them.
- Every parameter carries: current value, brain target, manual override (wins),
  and a confidence/reason string for the UI.
- Use TPT/state-variable filter topologies (not static RBJ biquads) anywhere the
  brain modulates params, to avoid zipper noise.

## Per-channel strip (signal order)
1. **Input trim (digital gain).** Normalize to ~-18 dBFS nominal. We inherit FOH
   preamp gain on the split and cannot change it, so this is the normalize stage.
2. **HPF.** 12/24 dB/oct Butterworth, corner per source class (speech 80–120 Hz,
   kick/bass full).
3. **Gate / expander.** Hysteresis (separate open/close thresholds) + few-ms
   look-ahead. Hard gates for drums/instruments only; speech mics use gentle
   downward expansion and rely on the automixer.
4. **Corrective EQ (pre-comp).** Parametric bands + dynamic EQ bands for resonance
   suppression and live feedback notching. Toward the source-class target curve.
5. **De-esser.** Dynamic band 5–9 kHz. Speech and lead vocal only.
6. **Compressor.** Feed-forward, log-domain gain computer, peak/RMS blended
   detection, program-dependent auto-release, auto-makeup. Settings by source class.
7. **Tonal / auto-EQ (post-comp).** Presence/air toward target curve.
8. **Fader (+ automix gain for speech mics).** Hits the per-scene balance target.
9. **Pan.** Narrow, mono-compatible.
10. **Sends.** Reverb post-fader; subgroup routing.

## Automixer (cross-channel, speech-mic group)
Dugan-style gain-sharing: each member gain `g_i = level_i / sum(level_j over open
mics)`, so gains sum to unity. Short-term level estimate with a time constant and a
noise-floor offset, NOM compensation, and a last-mic-on floor. Replaces aggressive
gating on speech. Detector attack/release timing is derived from each processed
block's duration, and is behavior-tested for first-talker acquisition and handoff at
96 kHz. Highest-value autonomy block.

## Bussing
- **Audio subgroups** (sum + process): drums, band/instruments, vocals, speech
  (automix members), tracks/playback, reverb return.
- **DCA-style logical groups** (control-only, no re-sum): "band", "vocals", etc.,
  for scene-level moves.
- Flow: channels → subgroups → master. Reverb sends → reverb bus → master.

## Master bus
- Glue compressor (gentle, slow, ~2:1).
- Master tonal EQ (broadcast voicing).
- Loudness: BS.1770 LUFS metering, target ~-14 LUFS integrated, true-peak ceiling
  ~-1 dBTP, true-peak look-ahead limiter as final safety.
- Native slow correction uses completed three-second short-term LUFS, moves at most
  1 dB/second within ±6 dB, ignores silence, and yields to limiter activity.

## Reverb
Convolution with 2–3 curated impulse responses. No from-scratch algorithmic reverb.

## Scene layer (Planning Center driven)
A scene is a snapshot of: per-channel targets, DCA group levels, automix
membership/weights, reverb sends, master targets. Pull the order of service from
Planning Center Services and map items to scenes. Transitions ramp 1–2 s, never jump.

## Future brain jobs (control rate, off the audio thread)
- **Channel classification:** optional future classifier on log-mel spectrograms,
  ~12 church source classes. Run at soundcheck + occasional rechecks, never in the
  realtime callback and never required for pass-through/mixing.
- **Auto-EQ:** FFT, long-term average spectrum per channel, fit corrective/tonal
  bands toward the source-class target curve.
- **Auto-levels:** measurement + small regression/lookup to per-scene balance targets.
- **Feedback/resonance:** dynamic EQ notching.
- **Masking (v2):** cross-channel carving.

## Ground truth / data flywheel
Record raw multitracks + the human-approved mix every service as labeled training
data. "Good" = moving toward approved human mixes per source class and style.
Solves cold-start.

## Failsafe / trust (build into step 1)
- Watchdog on the brain thread.
- Hard bypass to a safe static mix, one button, always available.
- If the whole app dies, audio must still flow (pre-baked or hardware passthrough).
  Never silence on the stream.
- Automation conservative when live: rate-limit moves, confidence-gate uncertain
  decisions, hold last-good values, and let FREEZE stop control-thread changes.
- Always record raw multitracks + output (safety, forensics, training). The native
  milestone implements automatic or operator-requested checkpointed 60-second
  float-WAV segments through a preallocated two-second SPSC ring and dedicated file
  queue. Recorder overflow is explicit telemetry and never blocks the audio callback.
  Capture start is gated on planned-duration capacity plus a configured reserve,
  capacity is monitored while live, and optional retention moves only cleanly closed
  sessions to Trash. Archive export remains an explicit post-service operator step.

## Supervisory UI
Per-channel: label + confidence, EQ moves, level rides. Dual metering pre/post.
Manual override on everything. Remote monitoring so an operator can watch/intervene
off-site.

## Latency / sync
Broadcast-only gives 30–50 ms+ headroom → look-ahead is fine everywhere. But hit lip
sync: expose fixed DSP and estimated route latency, then measure both audio and video
end-to-end and compensate the faster path. Re-measure after route/buffer/encoder
changes and prove that the offset does not drift over a multi-hour run.

## Real-world robustness
- Dante needs a hardware leader clock; guard against sample-rate mismatch.
- Handle repatching/guests/label drift: fast re-identification + dead-simple operator
  control to correct and lock labels.

## Build order
1. Engine skeleton: I/O → per-channel strip → subgroups → master (glue comp +
   LUFS/true-peak limiter) → out. All params controllable + manual override. Static
   settings, no AI yet. Already a working software broadcast console.
2. Add the gain-sharing automixer on the speech group. Spoken word runs itself.
3. Add more brain features: measurement-driven gain staging, adaptive gates,
   conservative per-scene level riding, and the slow master loudness loop are now
   present. Next: optional classifier labels, spectral auto-EQ to target curves,
   and Planning Center scene driving.
   Keep every decision off the realtime callback.
4. v2: cross-channel masking, dynamic feedback suppression, learned scene behaviors,
   remote-monitoring polish.

Failsafe layer present from step 1 onward.
