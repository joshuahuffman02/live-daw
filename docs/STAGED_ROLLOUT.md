# Staged Autonomous Rollout

Production authority expands only after evidence from the lower-risk phase. Sermon is
first because speech automation has fewer interacting sources than a worship mix.

## Entry conditions

- Real DVS/HD96 input is visible as 64 float channels at 96 kHz.
- An isolated stereo encoder/virtual output is visible and cannot return to FOH.
- Service role map, Dante-to-mixer channel map, and intended stereo links have been
  reviewed; linked pairs are adjacent, same-role, non-overlapping, and labeled L/R.
- External static backup and fail-safe switching pass every kill test in
  `EXTERNAL_FAILOVER.md`.
- Encoder and public-egress health endpoints are configured and independently
  observed. Use the authenticated local OBS bridge and an HLS observer on a
  separate host/Internet connection; connect the latter through a restricted
  VPN/firewall path as described in `egress/README.md`.
- The signed app is installed at its permanent path; the LaunchAgent is installed.
  The proof runner independently requires a valid signature, stapled notarization
  ticket, and Gatekeeper acceptance, then records the signing details and executable
  SHA-256 in `app-integrity.txt`.
- Continuous recording has adequate free space (about 91.2 GB/hour at 64+2 channels,
  96 kHz float). The staged runner now records raw inputs plus program for the complete
  stability window, refuses to start unless the planned capture plus reserve fits,
  rechecks the reserve while live, and semantically verifies every finalized WAV
  segment before it can report success.
- A fresh production-host readiness report passes and verifies as described in
  `PRODUCTION_HOST_READINESS.md`. Production runs require this report, re-run all
  eleven host checks, and bind it to the exact phase, app, profile, route,
  duration/reserve, and recording volume.

## Phase 1 — sermon

1. Run one full rehearsal in SHADOW. Native candidate snapshots start automatically;
   note the exact UTC window and use **Reveal** in the Automation section to preserve
   the completed JSONL file. Compare replay metrics and candidate moves with the
   operator-approved mix; correct roles/map/settings, not the recording. Follow
   `SHADOW_DECISION_EVIDENCE.md`.
2. Run a supervised sermon with automation enabled and a hand on SAFE/FREEZE.
3. Execute the real hardware proof for at least two hours:

```sh
HOST_READINESS_REPORT="/Volumes/Proof/AutoMix/sermon-readiness/automix-production-host-readiness.json" \
  STABILITY_SECONDS=7200 RECORDING_RESERVE_GB=20 \
  ./scripts/run-staged-hardware-proof.sh sermon \
  "/Applications/AutoMix Native.app" \
  "DANTE_INPUT_UID" "ENCODER_OUTPUT_UID" \
  "$HOME/Library/Application Support/AutoMix Native/VenueProfile.json" \
  "/Volumes/Proof/AutoMix"
```

4. Review the manifest, soundcheck WAV/report, stability report,
   `runtime-incident-evidence.json`, `stream-health-observations.tsv`, the
   continuous-recording proof report and its raw/program segments, and the
   external-failover recording. Complete the `rollout-observation` report from the
   full native SHADOW decision log and its exact start/completion times, supervised
   service observation log and exact window, and real Planning
   Center cue trace. Use a snapshot of `runtime-incidents.jsonl` covering the
   supervised service; its plan-loaded and scene-applied events are parsed against
   the reported plan ID, item count, applied cue count, and rollout timestamps. The
   incident report validates and binds the source
   journal and requires zero warning/critical events across the manifest-duration
   window. The runner probes both configured health endpoints throughout the full
   check and blocks after two
   consecutive failures or a missing healthy observation. Its final semantic gate
   additionally requires zero unhealthy rows, exact production observer contracts,
   the actual local/remote endpoint peers (rejecting any egress peer bound to the
   production Mac), stable observer identity/software,
   authenticated clean OBS counter progress, advancing decoded HLS media sequences,
   fresh advancing endpoint timestamps, a maximum seven-second observation gap, and
   at least 95% coverage of the requested window, as specified in
   `STREAM_HEALTH_EVIDENCE.md`. The recording verifier requires zero
   dropped frames, exact segment/header/frame accounting, 66-channel 96 kHz float
   WAVs, the free-space reserve, and at least two persisted hours. The rollout
   verifier parses every native SHADOW snapshot, requiring one 64-channel/96 kHz
   non-simulated session, continuous time coverage, actual candidate movement, and no
   application of candidate automation to program.
5. A named operator accepts or rejects advancement. Any unexplained critical incident,
   missing speech, clipping, failover, restart, clock correction at the limit, or
   recorder loss blocks worship.

Record that decision only after the review. The venue owns an SSH signing key and an
`allowed_signers` file kept outside the evidence bundle:

```text
operator@example.org ssh-ed25519 AAAA... venue-acceptance
```

Use the fail-closed draft/finalize workflow in
`PRODUCTION_EVIDENCE_FORMAT.md` to produce the five external JSON reports. It
calculates attachment hashes and manifest/commit bindings; untouched or incomplete
templates cannot pass.

For an approved sermon, bind the exact proof and supporting evidence:

```sh
./scripts/record-proof-acceptance.sh \
  --phase sermon --decision approved \
  --reviewer "OPERATOR NAME" --signer "operator@example.org" \
  --signing-key "/secure/operator_ed25519" \
  --trusted-signers "/secure/live-daw-allowed-signers" \
  --source-commit "40_CHARACTER_GIT_SHA" \
  --app "/Applications/AutoMix Native.app" \
  --build-metadata "/Volumes/Proof/Release/build-metadata.json" \
  --manifest "/Volumes/Proof/AutoMix/sermon-.../automix-core-audio-full-check-....json" \
  --recording-report "/Volumes/Proof/AutoMix/sermon-.../automix-continuous-recording-.../continuous-recording-proof.json" \
  --app-integrity "/Volumes/Proof/AutoMix/sermon-.../app-integrity.txt" \
  --stream-health "/Volumes/Proof/AutoMix/sermon-.../stream-health-observations.tsv" \
  --runtime-incidents "/Volumes/Proof/AutoMix/sermon-.../runtime-incident-evidence.json" \
  --external-failover "/Volumes/Proof/AutoMix/sermon-.../external-failover-evidence.json" \
  --latency-lipsync "/Volumes/Proof/AutoMix/sermon-.../latency-lipsync-evidence.json" \
  --runtime-resilience "/Volumes/Proof/AutoMix/sermon-.../runtime-resilience-evidence.json" \
  --replay-comparison "/Volumes/Proof/AutoMix/sermon-.../replay-comparison.json" \
  --rollout-observation "/Volumes/Proof/AutoMix/sermon-.../rollout-observation.json" \
  --output-root "/Volumes/Proof/AutoMix/acceptance" \
  --notes "Reviewed complete sermon evidence; no blocking exceptions."
```

The command independently re-verifies the notarized app, full-check manifest,
two-hour recording, continuous encoder/egress coverage in
`STREAM_HEALTH_EVIDENCE.md`, the clean proof-window incident contract in
`RUNTIME_INCIDENT_EVIDENCE.md`, and the semantic production-evidence contract in
`PRODUCTION_EVIDENCE_FORMAT.md`. It checks that failover, A/V sync/drift, recovery
drills, replay results, the full SHADOW rehearsal, the supervised service, and the
real Planning Center cue trace pass their numeric and behavioral gates; hashes every
referenced attachment; binds all reports to the selected manifest; and binds the
replay candidate to the release source commit. It then hashes the complete evidence
index into `acceptance.json`, signs that exact JSON with the operator key, and
verifies the result against the venue trust file. A signed `rejected` decision is
retained just as durably but cannot unlock worship.

## Phase 2 — worship

Worship cannot run until the sermon manifest verifies as real hardware proof and its
post-review approval signature verifies against the venue trust file:

```sh
HOST_READINESS_REPORT="/Volumes/Proof/AutoMix/worship-readiness/automix-production-host-readiness.json" \
  STABILITY_SECONDS=7200 ./scripts/run-staged-hardware-proof.sh worship \
  "/Applications/AutoMix Native.app" \
  "DANTE_INPUT_UID" "ENCODER_OUTPUT_UID" \
  "$HOME/Library/Application Support/AutoMix Native/VenueProfile.json" \
  "/Volumes/Proof/AutoMix" \
  "/Volumes/Proof/AutoMix/sermon-.../automix-core-audio-full-check-....json" \
  "/Volumes/Proof/AutoMix/acceptance/sermon-acceptance-..." \
  "/secure/live-daw-allowed-signers"
```

The runner verifies the sermon scene and `hardwareProofPassed=true`, the acceptance
signature and trusted signer identity, every signed evidence hash, and the exact
sermon-manifest hash before it starts the worship full check. Start worship in SHADOW
rehearsal, then one supervised live service. Review vocal priority, stereo imaging,
playback, transients, limiter work, integrated loudness, scene transitions, and every
manual override.

Short commissioning exercises cannot be mistaken for production proof. Use, for
example,

```sh
REHEARSAL_ONLY=1 STABILITY_SECONDS=30 \
  ./scripts/run-staged-hardware-proof.sh sermon \
  "/Applications/AutoMix Native.app" \
  "DANTE_INPUT_UID" "ENCODER_OUTPUT_UID" \
  "$HOME/Library/Application Support/AutoMix Native/VenueProfile.json" \
  "/Volumes/Proof/AutoMix"
```

The same route, signature, health, and recording checks run, but the result is labeled
as rehearsal-only. A rehearsal may omit the host-readiness report and receives an
explicit warning. Without `REHEARSAL_ONLY=1`, the script rejects a missing readiness
report or a stability window shorter than 7,200 seconds.

## Production acceptance

Declare the mixer autonomous only when both scene manifests have
`hardwareProofPassed=true`, the external backup remained broadcast-safe through kill
tests, end-to-end A/V sync is measured, encoder and public egress stayed healthy, and
the reviewing operator records an approved, signed worship acceptance bundle using
the same command with `--phase worship` and
`--sermon-acceptance-dir`. The final worship bundle includes the sermon acceptance
JSON and signature hashes, so the complete promotion chain is preserved. Verify any
bundle with:

```sh
./scripts/verify-proof-acceptance.sh \
  --acceptance-dir "/Volumes/Proof/AutoMix/acceptance/worship-acceptance-..." \
  --trusted-signers "/secure/live-daw-allowed-signers" \
  --expected-phase worship \
  --expected-decision approved
```

Keep SAFE, FREEZE, Stop, and manual
channel-processing overrides available during every service. New device UIDs, Dante
patches, clock
leaders, buffer sizes, encoder settings, or material role-map changes invalidate the
evidence and require the affected phase again.
