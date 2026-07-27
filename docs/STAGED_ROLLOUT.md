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
  observed.
- The signed app is installed at its permanent path; the LaunchAgent is installed.
  The proof runner independently requires a valid signature, stapled notarization
  ticket, and Gatekeeper acceptance, then records the signing details and executable
  SHA-256 in `app-integrity.txt`.
- Continuous recording has adequate free space (about 91.2 GB/hour at 64+2 channels,
  96 kHz float). Set its planned duration at least as long as the service/proof, keep
  automatic start enabled for the supervised app run, and confirm the capacity gate
  passes before program begins.

## Phase 1 — sermon

1. Run one full rehearsal in SHADOW. Compare replay metrics and candidate moves with
   the operator-approved mix; correct roles/map/settings, not the recording.
2. Run a supervised sermon with automation enabled and a hand on SAFE/FREEZE.
3. Execute the real hardware proof for at least two hours:

```sh
STABILITY_SECONDS=7200 ./scripts/run-staged-hardware-proof.sh sermon \
  "/Applications/AutoMix Native.app" \
  "DANTE_INPUT_UID" "ENCODER_OUTPUT_UID" \
  "$HOME/Library/Application Support/AutoMix Native/VenueProfile.json" \
  "/Volumes/Proof/AutoMix"
```

4. Review the manifest, soundcheck WAV/report, stability report, incident JSONL,
   `stream-health-observations.tsv`, raw/program recording, and external-failover
   recording. The runner probes both configured health endpoints throughout the full
   check and blocks after two consecutive failures or a missing healthy observation.
5. A named operator accepts or rejects advancement. Any unexplained critical incident,
   missing speech, clipping, failover, restart, clock correction at the limit, or
   recorder loss blocks worship.

## Phase 2 — worship

Worship cannot run until the sermon manifest verifies as real hardware proof and a
named operator is recorded:

```sh
STABILITY_SECONDS=7200 ./scripts/run-staged-hardware-proof.sh worship \
  "/Applications/AutoMix Native.app" \
  "DANTE_INPUT_UID" "ENCODER_OUTPUT_UID" \
  "$HOME/Library/Application Support/AutoMix Native/VenueProfile.json" \
  "/Volumes/Proof/AutoMix" \
  "/Volumes/Proof/AutoMix/sermon-.../automix-core-audio-full-check-....json" \
  "OPERATOR NAME"
```

The runner verifies the sermon scene and `hardwareProofPassed=true`, writes a durable
acceptance JSON, then runs the worship full check. Start worship in SHADOW rehearsal,
then one supervised live service. Review vocal priority, stereo imaging, playback,
transients, limiter work, integrated loudness, scene transitions, and every manual
override.

## Production acceptance

Declare the mixer autonomous only when both scene manifests have
`hardwareProofPassed=true`, the external backup remained broadcast-safe through kill
tests, end-to-end A/V sync is measured, encoder and public egress stayed healthy, and
the reviewing operator signs the bundle. Keep SAFE, FREEZE, Stop, and manual
channel-processing overrides available during every service. New device UIDs, Dante
patches, clock
leaders, buffer sizes, encoder settings, or material role-map changes invalidate the
evidence and require the affected phase again.
