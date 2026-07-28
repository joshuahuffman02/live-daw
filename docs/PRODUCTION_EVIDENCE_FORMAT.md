# Production Evidence Format

The signed go-live decision accepts four machine-readable JSON reports. A report is
not valid merely because it exists: `verify-production-evidence.sh` validates every
required result, recomputes every attachment hash and byte count, binds all four
reports to the selected full-check manifest, and binds the replay candidate to the
accepted source commit.

Run the same check before review:

```sh
./scripts/verify-production-evidence.sh \
  --external-failover "/proof/external-failover.json" \
  --latency-lipsync "/proof/latency-lipsync.json" \
  --runtime-resilience "/proof/runtime-resilience.json" \
  --replay-comparison "/proof/replay-comparison.json" \
  --expected-manifest "/proof/automix-core-audio-full-check.json" \
  --expected-candidate-commit "40_CHARACTER_GIT_SHA" \
  --expected-phase sermon \
  --require-approved-replay
```

`record-proof-acceptance.sh` and `verify-proof-acceptance.sh` run this verifier
again. Consequently, a report or attachment that changes after review, belongs to a
different manifest, names a different candidate commit, or fails a semantic gate
cannot produce or verify an approved acceptance bundle.

## Fail-closed authoring workflow

Create all four drafts without hand-building schemas:

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
  --require-approved-replay
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

The deterministic fixture and rejection coverage live in
`scripts/test-production-evidence.sh` and
`scripts/test-production-evidence-authoring.sh`. They prove fail-closed drafts,
generated bindings/hashes, overwrite protection, and rejection of slow failover,
modified attachments, excessive residual sync, inconsistent drift math, restart
after operator Stop, unsafe evaluator metrics, incomplete decision logs, unsafe
approved replay, rejected promotion, wrong candidate commit, and evidence bound to
another manifest.
