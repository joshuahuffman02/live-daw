# AutoMix Appliance — C++/JUCE engine

This is the C++ DSP/control core plus a headless JUCE appliance shell. The current
native production app is [`../native`](../native): a SwiftUI/Core Audio macOS `.app`
that wraps this same DSP and brain code for the Midas HD96/Dante workflow. The
[`../web`](../web) app remains the runnable proof-of-concept of the same architecture
and the prototype/reference for higher-level brain behavior.

## What's here

```
appliance/
  dsp/        Pure-C++17 DSP core — NO JUCE dependency. The audio-thread engine.
  src/        JUCE app layer: audio-device I/O + the control-rate BrainThread.
  tests/      Standalone correctness tests for the DSP core (no JUCE, no audio device).
  CMakeLists.txt
```

### `dsp/` — the deterministic audio-thread engine (verified)
Per-sample DSP, no allocation/locking/ML in the hot path, all params ramped:

| File | What |
| --- | --- |
| `SVF.h` | TPT state-variable filter (the spec's required topology for modulated EQ) |
| `Biquad.h` | fixed biquads + BS.1770 K-weighting |
| `Gate.h` | gate / downward expander with hysteresis |
| `Compressor.h` | feed-forward, soft-knee, program-dependent release |
| `Automixer.h` | Dugan-style gain-sharing automixer |
| `Loudness.h` | BS.1770 momentary / short / gated-integrated LUFS |
| `Limiter.h` | 4× true-peak look-ahead brickwall limiter |
| `ChannelStrip.h` | the per-channel chain composed in spec order |
| `Engine.h` | channels → automix → buses → master → out, with **SAFE bypass** |

### `src/` — the JUCE app layer (buildable skeleton)
- `Main.cpp` — headless standalone shell; opens a Dante/Core Audio or ASIO device,
  runs `bdsp::Engine` on the audio thread, supervises with `BrainThread`, refuses to
  start unless the device is clocked at the HD96 target of 96 kHz, and clears any
  output channels beyond the first stereo pair instead of mirroring the stream mix
  into unintended routes.
- `BrainThread.h` — control-rate (~20 Hz) supervisor on its own thread. Computes
  parameter **targets** and hands them to the audio thread through an **atomic
  sequence mailbox** (the audio callback never blocks or takes the control mutex).
  It consumes atomically published input/post-strip levels for activity detection,
  idle-only noise-floor learning, bounded gain staging, adaptive gate thresholds,
  and conservative per-scene level riding. A separate master measurement closes a
  slow, limiter-aware loudness loop after a full short-term window. It includes the
  watchdog that drops to the SAFE mix if the brain stalls. The class-profile/scene
  tables here mirror the web brain; the **integration points** for any future
  classifier, spectral auto-EQ, and cross-channel masking are marked in comments.

## Build & test

The DSP core is verified with plain clang/gcc — no JUCE, no audio hardware:

```bash
# fastest: just the tests
clang++ -std=c++17 -O2 -Idsp -Isrc tests/test_dsp.cpp -o test_dsp && ./test_dsp

# or via CMake (tests only, no JUCE download)
cmake -B build -DBUILD_APP=OFF
cmake --build build
ctest --test-dir build --output-on-failure
```

The full appliance pulls JUCE 8 via CMake FetchContent on first configure:

```bash
cmake -B build            # downloads JUCE
cmake --build build --target BroadcastMixer
./build/BroadcastMixer_artefacts/BroadcastMixer   # select the Dante device as input
```

## Status — what's verified vs. scaffolded

- **Verified here:** the entire `dsp/` core, via 89 assertions in `tests/test_dsp.cpp`
  (filter response, +6 dB loudness scaling, the limiter never exceeding its ceiling,
  automixer gain sharing and 96 kHz acquisition/handoff timing, compressor/gate
  behavior, full-engine output under the ceiling, role-aware SAFE fallback behavior,
  96 kHz
  engine processing, bus/pan routing, live source-role reassignment,
  measurement-driven gain staging/activity/noise-floor behavior, bounded slow
  master loudness correction and limiter backoff, BrainThread manual override
  guards, and the no-allocation invariant for `Engine::process`, measurement
  publication, `BrainThread::applyTo`, and live channel config updates).
- **Native production path:** [`../native`](../native) wraps this same verified core
  in a real Apple Silicon macOS app with Core Audio device selection, HD96 preflight,
  channel mapping, soundcheck recording, stability monitoring, SAFE, FREEZE, and
  saved venue profiles.
- **Scaffolded (build locally with JUCE):** `src/` — a headless portability shell that
  wires the verified core to real Dante I/O and the two-rate brain. It now uses the
  HD96/Dante target as its fallback operating point, but the richer operator workflow
  is in the native app.

## Dante / deployment notes
- For the Midas Heritage-D HD96-24 workflow, run Dante Virtual Soundcard and the native
  app at 96 kHz. Dante needs a hardware **leader clock** on the network; guard against
  sample-rate mismatch (the native app reports selected-device sample rate).
- Take a **split** of the raw channels; never feed the room PA (no acoustic feedback
  path by design).
- Expose a fixed, known audio latency so the video encoder can compensate for lip sync.
- Always record raw multitracks + the output (forensics + the training-data flywheel).
- A failed app or powered-off Mac is outside the in-app watchdog's reach. Production
  requires the independent hardware/encoder fallback and kill tests in
  [`../docs/EXTERNAL_FAILOVER.md`](../docs/EXTERNAL_FAILOVER.md).
- Shipping a product on Dante may require an Audinate license/partnership — settle that
  before committing to the I/O design.
