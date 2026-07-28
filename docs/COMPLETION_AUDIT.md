# Production Completion Audit

Audited 2026-07-28 against the full autonomous-livestream objective. This document
separates verified software behavior from evidence that can exist only on the venue
rig. A passing simulator, unit test, or locally built app is never represented as
hardware proof.

## Requirement evidence

| Objective requirement | Authoritative evidence | Current determination |
| --- | --- | --- |
| Version control and CI | Private repository at `github.com/joshuahuffman02/live-daw`; clean published `main`; `.github/workflows/ci.yml` builds/tests DSP, replay, JUCE, web, native Debug/Release, and the monitor smoke | Source is published and local validation is green. Hosted macOS jobs are triggered, but GitHub stops them before checkout with `Actions budget is preventing further use`; no hosted test result is being claimed. |
| Behavior-tested speech automixer | `appliance/dsp/Automixer.h`; 96 kHz acquisition, equal-share, silence ducking, handoff, and no-allocation assertions in `appliance/tests/test_dsp.cpp` | Verified in deterministic tests. |
| Measurement-driven gain staging, activity/noise floor, adaptive gates, level riding, slow loudness normalization | `appliance/src/BrainThread.h`; measurement, loudness, limiter-backoff, FREEZE/SAFE, and shadow tests in `appliance/tests/test_dsp.cpp` | Verified in deterministic control-loop tests and native bridge integration. |
| Curated SAFE and whole-app/Mac fallback | Role-aware raw-input SAFE in `appliance/dsp/Engine.h`; worst-case 64-channel ceiling and speech-priority tests; `docs/EXTERNAL_FAILOVER.md` | In-app SAFE verified. Independent hardware/encoder fallback is fully specified but must be built and kill-tested on the venue system. |
| Safe scene transitions, manual overrides, Planning Center driving | Smoothed targets in the DSP/brain; full processing and mix-override bridge tests; Planning Center mapping/timed-cue tests; Keychain credential storage | Software verified. Live API/service-plan exercise still needs venue credentials and an actual service plan. |
| Worship roles and stereo linking | Role profiles for speech, vocals, guitars, bass, drums, keys, percussion, and playback; linked detector/control tests; profile/preflight coverage tests | Verified in deterministic and native simulation tests. |
| Latency and lip-sync reporting | Fixed limiter latency impulse test; native route estimate and persisted measured A/V path; `docs/LATENCY_AND_LIPSYNC.md` | Calculation/reporting verified. End-to-end camera/encoder measurement and multi-hour drift observation require the real chain. |
| Continuous raw/program recording | Preallocated SPSC recording path, 60-second checkpoint segments, capacity/retention controls, remapped-input-order and no-allocation tests; staged full-window recorder; `ContinuousRecordingProofReport` segment/frame/capacity verifier | Software and the headless proof integration are verified. Current internal disk still has insufficient space for the two-hour 64+2-channel hardware run. |
| Encoder/public-egress health, device recovery, relaunch, incident logging | Health contract and alert tests; exact-route recovery/backoff tests; LaunchAgent installer; incident JSONL; `docs/RUNTIME_RESILIENCE.md` | Software verified. Real encoder and public-egress endpoints plus crash/device drills remain external acceptance work. |
| Separate-device drift mitigation/shared clock | Bounded `AsyncOutputClock`, ring telemetry, correction-limit gates, route clock preflight, stability-report tests | Algorithm and gates verified. Real independent-device or Aggregate Device run remains hardware evidence. |
| Reproducible replay/evaluation and decision log | `appliance/tools/replay_eval.cpp`; deterministic self-test; CRC/config/metrics/20 Hz trace contract in `docs/REPLAY_EVALUATION.md` | Harness verified. Promotion still requires representative recorded services and operator-approved references. |
| SHADOW-first progressive autonomy | Candidate-only shadow behavior tests; venue profiles default SHADOW on; staged runner forces autonomous proof controls; `docs/STAGED_ROLLOUT.md` | Workflow and gates verified. Actual shadow rehearsal, supervised sermon, and supervised worship are not yet performed. |
| Dependency and security hygiene | Locked npm graph, zero high-level audit findings, current React/Vite/TypeScript/JUCE patch, pinned CI actions, least-privilege CI token, HttpOnly cookie-only remote control, pairing lockout/bounds, CSP | Verified locally; hosted Dependabot/CI begins after initial push. |
| Realtime safety and human authority | No-allocation guards for engine, automixer, reverb/delay, brain mailbox, native input/render/recording/overrun paths; SAFE/FREEZE/manual controls and tests | Verified in deterministic and simulated native paths. Real callback timing/xrun behavior remains a rig measurement. |
| Signed/notarized production artifact | Hardened Runtime, audio-input entitlement, fail-closed release builder, signature/notary/staple/Gatekeeper verification, proof runner binding | Pipeline verified through unsigned/ad-hoc negative and entitlement tests. No Developer ID Application identity or notary profile is installed, so no production artifact exists yet. |
| Real 64-channel 96 kHz HD96/Dante proof | Full-check runner, semantic manifest verifier, simulation-resistant source checks, notarized-build gate | Not achieved. Current inventory contains only built-in 48 kHz speakers and the explicit simulated HD96 device. |
| Sermon-autopilot milestone | Sermon-first staged runner, minimum two-hour health/stability/recording proof, post-review SSH-signed decision bundle, trusted-signer and evidence-hash verifier | Software gate verified; the approval itself is not achieved because it requires the production rig, complete evidence, and a supervised service. |
| Worship autonomy acceptance | Cryptographically verified approved sermon prerequisite bound to the exact manifest, recorded-service comparison, supervised worship proof, equivalent signed final go-live decision | Not achieved and deliberately gated behind verified sermon acceptance. |
| Operator UI/UX | Native operator shell, remote monitor, monitor wall, setup/onboarding, keyboard/screen-reader paths, responsive layouts, and critical-state visual hierarchy; `docs/UI_UX_AUDIT.md`; `design-qa.md` | Full product-flow audit and redesign implemented. Native/web builds and UI-facing tests pass locally; real operators must still validate the production rig workflow under service conditions. |

## Latest verified local results

- Deterministic DSP: **117 passed, 0 failed**.
- Replay evaluator: self-test passed.
- Native XCTest: **234 passed, 0 failed**.
- Remote monitor: static/auth/pairing/cookie/command/SSE smoke passed.
- Web proof: clean install, typecheck, production build, and `npm audit` passed
  with **0 known vulnerabilities**.
- JUCE 8.0.15 portability target: strict Release build and CTest passed.
- Xcode project regeneration: deterministic with the declared Brew tools.
- Full CMake graph: Release build and CTest passed.
- Staged recording proof: full stability-window capture, planned-capacity and live
  reserve gates, segment/header/frame verification, zero-drop requirement, and the
  two-hour production-vs-rehearsal gate are implemented and behavior-tested.
- Acceptance chain: signed-bundle, continuous stream-health, and semantic
  production-evidence self-tests pass. They reject evidence modified after signing,
  unhealthy/stale/gapped/short stream observations, slow/unsafe failover, excessive
  or inconsistent A/V drift, failed recovery behavior, unsafe replay, a mismatched
  replay commit, wrong rollout phase, and reports bound to another manifest. Worship
  requires a trusted approved sermon signer and an exact accepted-manifest hash
  match.
- Operator UI/UX redesign: native, remote, monitor, setup, accessibility, and
  responsive-layout changes committed as `f3e6e74`.
- Private repository publication: local `main` tracks the published private `main`.
- Hosted CI attempts:
  [push run 30380776472](https://github.com/joshuahuffman02/live-daw/actions/runs/30380776472)
  and subsequent Dependabot-triggered checks were rejected before any step ran by
  the account Actions budget gate.
- Worktree: clean after the verified publication slice.

## Current-host readiness facts

The latest inventory is under
`validation-artifacts/current-host-readiness/automix-core-audio-device-inventory-20260727-162905.json`
and is intentionally ignored from source control.

- `Mac mini Speakers`: 0 inputs, 2 outputs, 48 kHz, not a livestream-safe route.
- `Simulated HD96 Dante Split`: 64 inputs, 2 outputs, 96 kHz, explicitly labeled
  `simulated-hd96-dante`; it cannot set `hardwareProofPassed=true`.
- Developer ID signing identities: **0**.
- Dante/DVS, OBS, BlackHole, and Loopback applications: not found.
- Internal filesystem free space: approximately **21 GiB**.
- A 64-input + stereo-program 96 kHz float recording consumes about **91.2 GB/hour**,
  before reserve and other proof artifacts.

## Evidence still required for completion

1. Restore GitHub Actions minutes/billing for the repository owner and obtain a
   green hosted macOS CI run for the published source commit.
2. Install/activate DVS or attach the chosen 64-channel Dante interface; connect the
   HD96 split and clock the complete route at 96 kHz.
3. Provision an isolated stereo encoder/virtual output, encoder and public-egress
   health endpoints, and an external fail-safe backup/A-B path.
4. Provide a production recording volume with at least the calculated proof duration
   plus reserve (roughly 200+ GB free for a two-hour run).
5. Install the Apple Developer ID Application identity and notary Keychain profile;
   build the signed, notarized, stapled release.
6. Configure Planning Center credentials/plan, venue mapping, stereo links, measured
   A/V latency, and the reviewed static backup mix.
7. Run external kill tests, one full sermon SHADOW rehearsal, the supervised
   notarized sermon proof, and named acceptance.
8. Only after sermon acceptance, run recorded-service comparisons, worship SHADOW,
   the supervised worship proof, and final named go-live acceptance.

The goal is complete only when the sermon and worship manifests both verify
`hardwareProofPassed=true` and the external failover, encoder/egress, latency, storage,
signing, and operator-acceptance evidence are present.
