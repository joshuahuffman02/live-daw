# Production Completion Audit

Audited 2026-07-28 against the full autonomous-livestream objective. This document
separates verified software behavior from evidence that can exist only on the venue
rig. A passing simulator, unit test, or locally built app is never represented as
hardware proof.

## Requirement evidence

| Objective requirement | Authoritative evidence | Current determination |
| --- | --- | --- |
| Version control and CI | Private repository at `github.com/joshuahuffman02/live-daw`; clean published `main`; `.github/workflows/ci.yml` builds/tests evidence contracts, DSP, replay, JUCE, web, native Debug/Release, and the monitor smoke | Source is published. A slice is called green only when the hosted macOS 15 workflow succeeds for its exact commit; the stable workflow link below is the source of truth. |
| Behavior-tested speech automixer | `appliance/dsp/Automixer.h`; 96 kHz acquisition, equal-share, silence ducking, handoff, and no-allocation assertions in `appliance/tests/test_dsp.cpp` | Verified in deterministic tests. |
| Measurement-driven gain staging, activity/noise floor, adaptive gates, level riding, slow loudness normalization | `appliance/src/BrainThread.h`; measurement, loudness, limiter-backoff, FREEZE/SAFE, and shadow tests in `appliance/tests/test_dsp.cpp` | Verified in deterministic control-loop tests and native bridge integration. |
| Curated SAFE and whole-app/Mac fallback | Role-aware raw-input SAFE in `appliance/dsp/Engine.h`; worst-case 64-channel ceiling and speech-priority tests; stale-aware fail-closed `/health` primary-audio heartbeat; independent lease-based failover supervisor and 24-test state-machine/HTTP/relay suite; `docs/EXTERNAL_FAILOVER.md` | In-app SAFE and the independent controller software are verified. The normally de-energized relay/encoder backup path must still be built and kill-tested on the venue system. |
| Safe scene transitions, manual overrides, Planning Center driving | Smoothed targets in the DSP/brain; full processing and mix-override bridge tests; fail-closed startup/recovery/proof application plus visible durable live-edit rejection; Planning Center mapping/timed-cue tests; Keychain credential storage | Software verified. Live API/service-plan exercise still needs venue credentials and an actual service plan. |
| Worship roles and stereo linking | Role profiles for speech, vocals, guitars, bass, drums, keys, percussion, and playback; linked detector/control tests; profile/preflight coverage tests | Verified in deterministic and native simulation tests. |
| Latency and lip-sync reporting | Fixed limiter latency impulse test; native route estimate and persisted measured A/V path; `docs/LATENCY_AND_LIPSYNC.md` | Calculation/reporting verified. End-to-end camera/encoder measurement and multi-hour drift observation require the real chain. |
| Continuous raw/program recording | Preallocated SPSC recording path, 60-second checkpoint segments, capacity/retention controls, remapped-input-order and no-allocation tests; staged full-window recorder; `ContinuousRecordingProofReport` segment/frame/capacity verifier | Software and the headless proof integration are verified. Current internal disk still has insufficient space for the two-hour 64+2-channel hardware run. |
| Encoder/public-egress health, device recovery, relaunch, incident logging | Exact-role production health and signed-evidence contract tests; authenticated OBS WebSocket bridge with advancing counters and exact track/meter binding; independently deployable public HLS observer requiring public-peer sequence advancement, newest-segment retrieval, and decoded audio; signed proof binds actual endpoint peer, observer/software identity, and role-specific provenance; both LaunchAgent installers; 26 OBS plus 26 egress protocol/state/server tests; exact-route recovery/backoff; app LaunchAgent; incident JSONL; `docs/RUNTIME_RESILIENCE.md` | Concrete encoder and public-playback observer software paths are verified. The venue still needs its real BlackHole/capture input, authenticated OBS configuration, offsite/VPN egress deployment, real live stream, and crash/device drills. |
| Separate-device drift mitigation/shared clock | Bounded `AsyncOutputClock`, ring telemetry, correction-limit gates, route clock preflight, stability-report tests | Algorithm and gates verified. Real independent-device or Aggregate Device run remains hardware evidence. |
| Reproducible replay/evaluation and decision log | `appliance/tools/replay_eval.cpp`; deterministic self-test; CRC/config/metrics/20 Hz trace contract in `docs/REPLAY_EVALUATION.md` | Harness verified. Promotion still requires representative recorded services and operator-approved references. |
| SHADOW-first progressive autonomy | Candidate-only shadow behavior tests; venue profiles default SHADOW on; native one-second 64-channel candidate-decision JSONL; semantic coverage/route/non-application verifier; manifest/commit-bound `rollout-observation` evidence; `docs/STAGED_ROLLOUT.md` | Workflow and signed promotion gates are verified. An approved bundle now requires a full, continuous, non-simulated native SHADOW capture, supervised service, and reviewed real Planning Center cue trace. Those venue events have not yet occurred. |
| Dependency and security hygiene | Locked npm graph, zero high-level audit findings, current React/Vite/TypeScript/JUCE releases, pinned CI actions, least-privilege CI token, HttpOnly cookie-only remote control, pairing lockout/bounds, snapshot-bound remote commands, CSP | Verified locally and in the hosted macOS pipeline. |
| Realtime safety and human authority | No-allocation guards for engine, automixer, reverb/delay, brain mailbox, native input/render/recording/overrun paths; SAFE/FREEZE/manual controls and tests; fail-closed remote mutation on stale telemetry, 750 ms pre-routing expiry, one-second acknowledgement timeout, and local-only FREEZE | Verified in deterministic and simulated native paths. Real callback timing/xrun behavior remains a rig measurement. |
| Signed/notarized production artifact | Hardened Runtime, audio-input entitlement, fail-closed release builder, code-signature-sealed source provenance, executable/release-metadata hash binding, signature/notary/staple/Gatekeeper verification, proof runner and signed-acceptance cross-binding | Pipeline verified through unsigned/ad-hoc, provenance-mismatch, and entitlement negative tests. No Developer ID Application identity or notary profile is installed, so no production artifact exists yet. |
| Real 64-channel 96 kHz HD96/Dante proof | Full-check runner, semantic manifest verifier, simulation-resistant source checks, notarized-build gate | Not achieved. Current inventory contains only built-in 48 kHz speakers and the explicit simulated HD96 device. |
| Sermon-autopilot milestone | Sermon-first staged runner, minimum two-hour health/stability/recording proof, post-review SSH-signed decision bundle, trusted-signer and evidence-hash verifier | Software gate verified; the approval itself is not achieved because it requires the production rig, complete evidence, and a supervised service. |
| Worship autonomy acceptance | Cryptographically verified approved sermon prerequisite bound to the exact manifest, recorded-service comparison, supervised worship proof, equivalent signed final go-live decision | Not achieved and deliberately gated behind verified sermon acceptance. |
| Operator UI/UX | Native operator shell, remote monitor, monitor wall, setup/onboarding, keyboard/screen-reader paths, responsive layouts, critical-state visual hierarchy, and stale-telemetry remote-control lock; `docs/UI_UX_AUDIT.md`; `design-qa.md` | Full product-flow audit and redesign implemented. Native/web builds and UI-facing tests pass locally; real operators must still validate the production rig workflow under service conditions. |

## Latest verified local results

- Deterministic DSP: **117 passed, 0 failed**.
- Replay evaluator: self-test passed.
- Native XCTest: **258 passed, 0 failed**, including fail-closed startup,
  operator-visible incident behavior when the native bridge rejects a saved or live
  manual override, and an honest remote NACK when native control is not applied.
- Remote monitor: static/auth/pairing/cookie, heartbeat, snapshot-freshness,
  SAFE-release confirmation, bounded command timeout, and SSE smoke passed.
- Remote browser control safety: **6 passed, 0 failed** for forward-only timestamp
  progression, duplicate-frame stall detection, backward-clock reset,
  transport loss/recovery, contract validation, and command-to-snapshot binding.
- Browser master safety: **3 passed, 0 failed** for sustained overload, isolated
  full-scale transients, post-limiter true-peak ceiling compliance, and transparent
  sub-ceiling operation.
- Production-host readiness audit: **12 passed, 0 failed** for complete and blocked
  fixture hosts, simulated-route relabel rejection, token-bearing URL redaction,
  redirect/compressed-response refusal, loopback/control-character URL rejection,
  atomic owner-only report handling, Developer ID/Hardened Runtime/production-
  entitlement enforcement, signed-app/release-metadata mismatch rejection, and fresh
  hash-bound report re-verification, including rejection when a production staged
  run tries to skip the gate.
  Production staged runs bind it to the exact phase, app, signed release metadata,
  profile, route, duration, reserve, and recording volume. The real-host result is
  deliberately not a production-acceptance substitute.
- Independent failover supervisor: **24 passed, 0 failed** for fail-closed
  heartbeat validation, startup/restart defaults, short primary leases, manual-only
  return, relay acknowledgement binding, controller state, and private operator
  control/status.
- OBS encoder-health bridge: **26 passed, 0 failed** for authenticated WebSocket v5
  negotiation, advancing encoder counters, exact name/UUID program-input track and
  carrier binding, honest observation age, stale and malformed observations,
  immediate stop/reconnect failure, recovery/session-invalidated behavior, socket
  cleanup, owner-only password handling, loopback confinement, and no-store HTTP
  health.
- Public HLS egress observer: **26 passed, 0 failed** for production URL/public-peer
  confinement, redirects and byte ranges, master/audio rendition selection,
  sequence/delta/map/range parsing, finite/encrypted rejection, owner-only URL
  handling, real FFmpeg silent-carrier decode, baseline/progression/stall/reset
  behavior, playback failure, URL redaction, and no-store HTTP health.
- Web proof: clean install, typecheck, production build, and `npm audit` passed
  with **0 known vulnerabilities**. The running proof now exposes convergence-bound
  scene transitions, held FREEZE/SAFE cues, actionable Planning Center recovery,
  post-limiter output true peak, limiter-input pressure, and bounded autonomous
  loudness trim.
- JUCE 9.0.0 portability target: strict Release build and CTest passed.
- Xcode project regeneration: deterministic with the declared Brew tools.
- Full CMake graph: Release build and CTest passed.
- Staged recording proof: full stability-window capture, planned-capacity and live
  reserve gates, segment/header/frame verification, zero-drop requirement, and the
  two-hour production-vs-rehearsal gate are implemented and behavior-tested.
- Acceptance chain: signed-bundle, continuous stream-health, and semantic
  production-evidence self-tests pass. The manifest-duration incident snapshot also
  rejects malformed journals, hidden warning/critical events, short windows, and
  manifest substitution. Fail-closed authoring tests prove template defaults cannot
  pass, bindings/hashes are generated, and finalized reports are not silently
  overwritten. The complete chain cross-binds the signed in-app source provenance,
  release metadata, executable hash, signature log, and structured integrity report;
  it rejects a freshly re-signed decision that mixes those between builds, evidence
  modified after signing, unhealthy/stale/gapped/short stream observations,
  slow/unsafe failover, excessive or inconsistent A/V drift, failed recovery
  behavior, unsafe replay, a mismatched replay commit, SHADOW automation applied to
  program, an unsupervised service,
  simulated/generic-route, short, gapped, silent, frozen, or overlapping SHADOW evidence,
  unexpected Planning Center scene changes, Planning Center traces from another
  plan or with missing cue events, wrong rollout phase, and reports bound to another
  manifest. Worship
  requires a trusted approved sermon signer and an exact accepted-manifest hash
  match.
- Operator UI/UX redesign: native, remote, monitor, setup, accessibility, and
  responsive-layout changes committed as `f3e6e74`; the later remote safety audit
  verifies fail-closed startup, telemetry loss, and automatic recovery at phone size.
- Private repository publication: local `main` tracks the published private `main`.
- Hosted macOS 15
  [CI workflow](https://github.com/joshuahuffman02/live-daw/actions/workflows/ci.yml)
  verifies evidence contracts, deterministic project generation, DSP, replay, JUCE,
  npm audit/typecheck/build, native XCTest, monitor smoke, and native Release build
  for every published commit.
- Device-inventory proof hardening: production input/output candidates are derived
  from enumerated device identities, simulated devices are separately disclosed and
  excluded, missing or edited production fields fail closed, and a simulated route
  relabeled as real Core Audio hardware is rejected.
- Worktree: clean after the verified publication slice.

## Current-host readiness facts

The latest inventory is under
`validation-artifacts/current-host-readiness/automix-core-audio-device-inventory-20260728-164523.json`
and is intentionally ignored from source control.

- `ThinkPad Thunderbolt 3 Dock USB Audio`: separate 1-input and 2-output 48 kHz
  endpoints; neither satisfies the 64-input/96 kHz isolated-stream route.
- `Mac mini Speakers`: 0 inputs, 2 outputs, 48 kHz, not a livestream-safe route.
- `Simulated HD96 Dante Split`: 64 inputs, 2 outputs, 96 kHz, explicitly labeled
  `simulated-hd96-dante`; it is excluded from both production candidate counts and
  cannot set `hardwareProofPassed=true`.
- Fresh inventory result: **0 production HD96 input candidates**, **0 production
  stream output candidates**, and **1 simulated device excluded**.
- Developer ID signing identities: **0**.
- OBS Studio **32.2.1** is installed in `/Applications`, passes strict deep code
  signature verification, and is accepted by Gatekeeper as a notarized Developer ID
  build. Its bundled OBS WebSocket plugin is present. The repository now contains the
  concrete OBS health bridge and installer, but the bridge is not installed because
  OBS does not yet have the real program-audio input or venue WebSocket password.
- FFmpeg **8.1.2_1** is installed and the public HLS observer's real silent-carrier
  decode test passes. The observer is not deployed because no public platform HLS
  playback URL, offsite observer host/network, or private VPN path has been
  provisioned.
- Dante/DVS, BlackHole, and Loopback applications: not found. BlackHole 2ch requires
  an administrator-approved package installation and a reboot before it can be
  evaluated as the isolated program-output route.
- Internal filesystem free space: approximately **22 GiB** in the latest automated
  host-readiness audit.
- A 64-input + stereo-program 96 kHz float recording consumes about **91.2 GB/hour**,
  before reserve and other proof artifacts.

## Evidence still required for completion

1. Install/activate DVS or attach the chosen 64-channel Dante interface; connect the
   HD96 split and clock the complete route at 96 kHz.
2. Install BlackHole/capture routing, create and verify the exact OBS program-audio
   input and authenticated WebSocket password, install the encoder-health bridge,
   deploy the HLS observer on an offsite network through a restricted VPN path, and
   build the external fail-safe backup/A-B path.
3. Provide a production recording volume with at least the calculated proof duration
   plus reserve (roughly 200+ GB free for a two-hour run).
4. Install the Apple Developer ID Application identity and notary Keychain profile;
   build the signed, notarized, stapled release.
5. Configure Planning Center credentials/plan, venue mapping, stereo links, measured
   A/V latency, and the reviewed static backup mix.
6. Run external kill tests, one full sermon SHADOW rehearsal, the supervised
   notarized sermon proof, and named acceptance.
7. Only after sermon acceptance, run recorded-service comparisons, worship SHADOW,
   the supervised worship proof, and final named go-live acceptance.

The goal is complete only when the sermon and worship manifests both verify
`hardwareProofPassed=true` and the external failover, encoder/egress, latency, storage,
signing, and operator-acceptance evidence are present.
