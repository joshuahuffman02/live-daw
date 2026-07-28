# Production Evidence Format

The signed go-live decision accepts five machine-readable JSON reports. A report is
not valid merely because it exists: `verify-production-evidence.sh` validates every
required result, recomputes every attachment hash and byte count, binds all five
reports to the selected full-check manifest, and binds both the replay and rollout
observations to the accepted source commit.

Run the same check before review:

```sh
./scripts/verify-production-evidence.sh \
  --external-failover "/proof/external-failover.json" \
  --latency-lipsync "/proof/latency-lipsync.json" \
  --runtime-resilience "/proof/runtime-resilience.json" \
  --replay-comparison "/proof/replay-comparison.json" \
  --rollout-observation "/proof/rollout-observation.json" \
  --expected-manifest "/proof/automix-core-audio-full-check.json" \
  --expected-candidate-commit "40_CHARACTER_GIT_SHA" \
  --expected-phase sermon \
  --require-approved-replay \
  --require-approved-rollout
```

`record-proof-acceptance.sh` and `verify-proof-acceptance.sh` run this verifier
again. Consequently, a report or attachment that changes after review, belongs to a
different manifest, names a different candidate commit, or fails a semantic gate
cannot produce or verify an approved acceptance bundle.

Acceptance envelopes use `formatVersion: 2`. Version 2 is intentionally incompatible
with the earlier ten-item envelope because it makes `rollout-observation` the
eleventh required signed evidence item. A version 1 decision cannot unlock worship
or production go-live.

## Fail-closed authoring workflow

Create all five drafts without hand-building schemas:

```sh
./scripts/new-production-evidence-drafts.sh \
  --phase sermon \
  --output-dir "/proof/evidence-drafts"
```

The generated JSON files contain every required test ID and field, but unsafe
defaults (`false`, impossible measurements, mismatched CRCs, and `/REPLACE/...`
paths) make untouched or partially completed drafts impossible to approve. Fill the
actual venue measurements, observations, reviewer judgments, commits/CRCs, corpus
entries, and absolute attachment paths. Duplicate the replay comparison object when
the corpus has more than one recording.

Finalize only after the drafts are complete:

```sh
./scripts/finalize-production-evidence.sh \
  --draft-dir "/proof/evidence-drafts" \
  --manifest "/proof/automix-core-audio-full-check.json" \
  --candidate-commit "40_CHARACTER_GIT_SHA" \
  --output-dir "/proof/evidence-final" \
  --require-approved-replay \
  --require-approved-rollout
```

The finalizer refuses a failed/simulated manifest, fills the exact manifest and
candidate bindings, canonicalizes every attachment path, computes every SHA-256 and
byte count, removes draft-only instructions, and runs the complete semantic
verifier before publishing any final report. Drafts and final output must be in
different directories. Existing drafts or final reports are never overwritten
without explicit `--replace`.

## Common report fields

Every report is JSON readable by macOS `plutil` and contains:

| Field | Required value |
| --- | --- |
| `formatVersion` | Integer `1` |
| `proofType` | The exact report type named below |
| `completedAtUTC` | UTC timestamp such as `2026-07-28T00:00:00Z` |
| `venueRig` | Boolean `true`; simulated evidence is never accepted |
| `phase` | `sermon` or `worship`, matching the acceptance under review |
| `fullCheckManifestSHA256` | SHA-256 of the exact full-check manifest under review |

Every attachment is an object with:

```json
{
  "path": "/absolute/path/to/evidence",
  "sha256": "64_lowercase_hex_characters",
  "bytes": 1234
}
```

Paths must be absolute, files must be non-empty, and the recorded hash and byte count
must match the current file. Store reports and attachments on the durable proof
volume before signing; moving them invalidates the absolute-path evidence contract.

## External failover report

Use `proofType: "external-failover"`. The top level requires:

- non-empty `switchModel`, `primaryEncoderInput`, `backupEncoderInput`, and
  `heartbeatMechanism`; the two encoder inputs must differ;
- `backupIsDefaultState`, `manualReturnOnly`, `broadcastIsolationConfirmed`, and
  `manualReturnVerified` set to `true`;
- `truePeakCeilingDbTP` from −30 through −1 dBTP;
- a `wiringDiagram` attachment;
- exactly five `tests`, with IDs `force-quit-app`, `stop-dvs-core-audio`,
  `disconnect-dante-network`, `remove-output-device`, and `power-off-mac`.

Every test requires `passed`, `programAudioPresent`, `bothEncoderInputsRecorded`,
`selectedOutputRecorded`, `speechIntelligible`, `stateVisible`, and
`heldBackupUntilManualReturn` to be `true`; `fohReturnLeakDetected` and
`oscillationDetected` must be `false`. `switchTimeSeconds` and
`maxSilentGapSeconds` must each be at most 2.0. `selectedOutputTruePeakDbTP` must not
exceed the declared ceiling. Each test also carries its own `recording` attachment.

## Latency and lip-sync report

Use `proofType: "latency-lipsync"`. Required fields are:

- `productionRouteVerified: true`, a non-empty `measurementMethod`,
  `warmupMinutes >= 30`, and `sampleCount >= 10`;
- numeric `audioPathMedianMs` and `videoPathMedianMs`;
- `compensation.target` equal to `audio`, `video`, or `none`, plus
  `compensation.delayMs`; the target must delay the earlier path and the delay must
  match the measured median difference within 1 ms;
- `venueAcceptanceLimitMs` no greater than 20 and `residualMedianOffsetMs` within
  that tighter venue limit;
- non-empty `clockTopology`, positive `inputBufferFrames` and `outputBufferFrames`,
  and non-negative `inputDeviceLatencyFrames`, `outputDeviceLatencyFrames`, and
  `separateOutputPrebufferFrames`;
- `driftObservation.durationSeconds >= 7200`, `syncEventCount >= 2`,
  `offsetChangeMs`, and the matching calculated `msPerHour`;
- `driftObservation.limitMsPerHour <= 20`, an observed rate within that limit,
  `withinLimit: true`, and `control` equal to `shared-clock`,
  `aggregate-device-drift-correction`, or `bounded-asrc`;
- `rawMeasurements` and `testRecording` attachments.

## Runtime resilience report

Use `proofType: "runtime-resilience"` and exactly seven passed tests. Every test has
an `evidence` attachment and one required ID:

| Test ID | Required observations |
| --- | --- |
| `callback-stall-recovery` | `unhealthyGraceSeconds` from 2–10 and `engineRestarted: true` |
| `output-device-reattach` | `boundedBackoffObserved: true`, `routeRecovered: true` |
| `recording-resume` | `newRecordingDirectoryCreated: true`, `wavHeadersValid: true` |
| `encoder-egress-alerts` | stale and unhealthy responses rejected; desktop and remote critical alerts observed |
| `launchagent-relaunch` | application relaunched; session and capture resumed |
| `operator-stop-no-restart` | `recoveryDisarmed: true`, `automaticRestartObserved: false` |
| `external-failover-handoff` | all kill tests passed and backup held until manual return |

## Replay comparison report

Use `proofType: "replay-comparison"`. It requires:

- non-empty `reviewer` and `findings`, and `decision` equal to `approved` or
  `rejected`;
- `blindListeningCompleted: true`, `baselineCommit`, and `candidateCommit`;
  candidate commit must equal the source commit being accepted;
- one or more `comparisons`, each with a unique `corpusID`,
  `completeServiceReviewed: true`, matching eight-hex `baselineSourceCRC32` and
  `candidateSourceCRC32`, and one or more `coverageTags`;
- per-comparison attachments at `baseline.program`, `baseline.metrics`,
  `baseline.decisions`, `candidate.program`, `candidate.metrics`,
  `candidate.decisions`, and `referenceMix`;
- per-comparison boolean checks `finiteOutput`, `noUnexpectedSilence`,
  `noClippingRegression`, `noSustainedLimiterReduction`,
  `noUnexplainedDecisionJumps`, `loudnessWithinTolerance`, and
  `blindListeningPassed`.

Every check must be `true` when `decision` is `approved`. Rejected comparison reports
may preserve false checks for diagnosis, but an approved production acceptance
requires an approved replay report. The validator parses the attached baseline and
candidate metrics rather than trusting a summary flag: both must use evaluator schema
2, carry the declared source CRC32, have identical scene/roles/stereo pairs/sample
rate/block size/channel/frame/tick configuration, and—when approved—report safe,
finite, reference-backed output. Each metrics file must represent at least five
minutes, its duration and 20 Hz tick count must agree with its frames/sample rate,
and each attached decision JSONL must contain exactly that number of control-tick
records.

Across the comparison set, sermon evidence must cover `sermon`, `prayer`,
`walk-in-out-playback`, `quiet-speaker`, `loud-speaker`, `panel-handoff`,
`intentional-silence`, `feedback-noise`, `missing-channel`, and `repatched-role`.
Worship evidence must also cover `dense-worship`. A recording may carry multiple
coverage tags, but every comparison still needs its own CRC, outputs, metrics,
decision logs, reference mix, and complete-service review.

## Rollout observation report

Use `proofType: "rollout-observation"`. This report closes the gap between laboratory
behavior and staged authority. It carries non-empty `reviewer` and `findings`,
`decision` equal to `approved` or `rejected`, and `candidateCommit` equal to the
source commit under acceptance.

An approved report requires all of the following:

- `shadowRehearsal` records a complete service, confirms automation was not applied
  to program, confirms the operator compared the candidate behavior, reports zero
  blocking issues, records exact `startedAtUTC`/`completedAtUTC` bounds, and attaches
  the native live candidate decision log;
- `supervisedService` records a complete service with automation enabled and a human
  operator present in its exact `startedAtUTC`/`completedAtUTC` window; SAFE, FREEZE,
  and manual override must have been available;
  missing-speech, clipping, and unexplained-critical-incident counts must all be
  zero; every operator intervention must be reviewed; and the observation log is
  attached;
- `planningCenter` identifies a real service plan, records at least one plan item and
  applied cue, proves the mappings were reviewed, reports zero unexpected scene
  changes, confirms the offline/manual fallback was tested, and attaches the cue
  trace. Applied cues cannot exceed plan items.

The cue trace is a JSONL snapshot from the native runtime incident journal covering
the supervised service. Approval parses every line and requires:

- at least one `planning-center-plan-loaded` event whose `planID`, `itemCount`, and
  recognized cue count are consistent with the report;
- exactly `appliedCueCount` matching `planning-center-scene-applied` events, each
  carrying that plan ID, a cue ID/index, a valid scene, and `operator` or
  `timed plan` as its source;
- all matching events after the SHADOW rehearsal and no later than supervised-service
  completion, with the plan load preceding the first applied cue.

The three attachments are independently hashed. A non-empty placeholder or a trace
from another plan is therefore insufficient. A rejected report may preserve failed
observations for diagnosis, but `--require-approved-rollout` and every approved signed
acceptance reject it.

The SHADOW attachment is also parsed rather than trusted by filename or size. The
native one-second snapshot contract proves a continuous 64-channel/96 kHz,
explicitly identified non-simulated HD96/Dante input and isolated stream-facing output
session; engine SHADOW remained active; candidate automation never reached program;
the expected phase, active input, observable program output, and measurable
candidate-state changes occurred; SAFE/FREEZE did not suppress more than 10% of the
comparison; and no observation gap exceeded five seconds. Coverage must span at least
95% of the reported rehearsal window. See
`SHADOW_DECISION_EVIDENCE.md`.

The deterministic fixture and rejection coverage live in
`scripts/test-production-evidence.sh` and
`scripts/test-production-evidence-authoring.sh`. They prove fail-closed drafts,
generated bindings/hashes, overwrite protection, and rejection of slow failover,
modified attachments, excessive residual sync, inconsistent drift math, restart
after operator Stop, unsafe evaluator metrics, incomplete decision logs, unsafe
approved replay, SHADOW automation reaching program, unsupervised service evidence,
simulated or gapped native SHADOW capture, overlapping rollout windows, unexpected
Planning Center scene changes, a cue trace from another plan, a trace with missing cue
events, rejected promotion, wrong candidate commit, and evidence bound to another
manifest.
