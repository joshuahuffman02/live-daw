# Recorded-Service Replay and Evaluation

`automix_replay` runs recorded inputs through the same `bdsp::Engine` and
`app::BrainThread` used by the native app. Its 20 Hz brain clock advances from WAV
frame positions, so the output and decision sequence are reproducible and do not
depend on machine speed.

## Build

```bash
clang++ -std=c++17 -O2 \
  -Iappliance/dsp -Iappliance/src -Iappliance/tools \
  appliance/tools/replay_eval.cpp \
  -o /tmp/automix-replay

/tmp/automix-replay --self-test
```

For a segmented session created by AutoMix Native, choose **Prepare replay** in the
Sessions workspace and run the generated request through the non-destructive session
runner:

```bash
scripts/run-recording-session-replay.py \
  "/path/to/session/Derived/Replay Request.json" \
  --replay-binary /tmp/automix-replay
```

Every invocation gets a new output directory and an aggregate index. The runner
validates that source and destination paths remain inside the session, preserves
partial diagnostics, and never changes source WAVs. It currently invokes the engine
independently for each 60-second segment; control state therefore restarts at segment
boundaries. Use those outputs for segment-level listening/triage, not as evidence of
continuous cross-boundary control behavior. See
[`MULTI_SESSION_RECORDING.md`](MULTI_SESSION_RECORDING.md).

## Input contract

- WAV may be PCM16, PCM24, PCM32, or IEEE float32.
- The `--roles` list defines the raw input channel count and order.
- The WAV must contain exactly that many channels, or that many plus a final stereo
  human/reference mix.
- Supported role names are `speech`, `leadVocal`, `bgv`, `acousticGuitar`,
  `electricGuitar`, `bass`, `kick`, `snare`, `tom`, `overhead`, `percussion`,
  `keys`, `playback` (or `tracks`), and `unknown`.
- `--stereo-pairs` is optional and uses 1-based adjacent channel pairs, for example
  `11-12,18-19`. Each pair must have the same assigned non-speech role and pairs
  cannot overlap.
- Use the same role order, stereo pairs, and scene for every comparison of one
  service.

Example for a four-input file with a final stereo reference (six WAV channels total):

```bash
/tmp/automix-replay \
  --input validation-artifacts/service-01.wav \
  --roles speech,leadVocal,keys,keys \
  --stereo-pairs 3-4 \
  --scene worship \
  --block-size 256 \
  --output validation-artifacts/service-01-program.wav \
  --metrics validation-artifacts/service-01-metrics.json \
  --decisions validation-artifacts/service-01-decisions.jsonl
```

The output WAV is always stereo float32. Metrics schema version 2 records source
CRC32, role order, stereo pairs, render configuration, duration, output LUFS/sample
peak, maximum limiter reduction, final loudness correction, activity/finite-output
checks, reference LUFS delta when available, and an electrical `safetyPassed` result.

The JSONL decision log has one record per 20 Hz control tick. Every record includes:

- exact source frame/time and scene;
- master loudness readiness/readings, limiter reduction, and automatic trim;
- each channel's role and 1-based stereo peer (or `null`), input RMS/peak, post-strip
  RMS, activity state, learned noise floor, automatic trim, and automatic fader
  target.

`safetyPassed` means the renderer remained finite, did not exceed the -1 dBTP
limiter's sample-peak tolerance, and did not turn active input into silence. It does
not mean the mix is artistically approved.

## Regression and shadow-mode gate

For every algorithm change:

1. Replay the same corpus on the last approved commit and candidate commit.
2. Keep input WAVs, role order, scene, sample rate, and block size identical; verify
   matching source CRC32 values.
3. Reject any candidate with `safetyPassed=false`, non-finite output, unexpected
   silence, sustained limiter gain reduction, or unexplained decision jumps.
4. Compare integrated/short-term loudness and the decision JSONL against the
   human/reference mix. Listen blind to the complete output, transitions, speech
   handoffs, and the worst metric deltas.
5. Record reviewer, commit, corpus IDs, findings, and approve/reject disposition.
6. Only then run the candidate in native SHADOW mode (the saved-profile default).
   The UI exposes candidates while the program retains static role/scene targets.
   Compare a complete service before disabling SHADOW and enabling one automation
   family at a time under supervision.

Record the comparison, exact commits/CRC32 values, outputs, metrics, decision logs,
reference mix, checks, findings, and disposition in the `replay-comparison` JSON
contract in `PRODUCTION_EVIDENCE_FORMAT.md`. Production approval verifies that the
candidate commit is the exact signed source commit; each corpus entry has matching
source CRC and render configuration; the attached evaluator metrics and decision-log
lengths are internally consistent; representative scenario coverage is present; and
every safety and blind listening check is true.

The replay corpus should include sermons, prayers, walk-in/out playback, quiet
speakers, loud speakers, panel/two-mic handoffs, worship with dense instrumentation,
intentional silence, feedback/noise incidents, missing channels, and repatched roles.
Do not tune only against a single service.
