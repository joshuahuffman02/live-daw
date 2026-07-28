# Native SHADOW Decision Evidence

The native app records the candidate control state once per second whenever the Core
Audio engine is running with SHADOW enabled. This is the live counterpart to the
offline replay decision log: program continues to use the non-autonomous path while
the same supervisory loop computes candidate trim, fader, activity, noise-floor, and
master-loudness moves.

## Capture behavior

Capture starts automatically after the engine enters SHADOW and writes JSON Lines
under:

`~/Library/Application Support/AutoMix Native/Shadow Decisions/`

The Automation section shows the current snapshot count and provides **Reveal** for
the active/latest file. Capture stops when the operator disables SHADOW or stops the
engine. A new SHADOW session creates a new file and session ID; files are never
silently reused.

Each `shadow-candidate-snapshot` includes:

- timestamp, session ID, scene, and the engine's actual SHADOW state;
- whether candidate automation was applied to program;
- SAFE and FREEZE state;
- exact input/output UIDs, sample rate, and channel count;
- input level, candidate auto-trim, candidate auto-fader, learned noise floor, and
  activity for every channel;
- candidate master loudness trim and observed program L/R levels.

The app builds snapshots on the control side and appends them through an actor-backed
file writer. The audio callback never allocates, encodes JSON, or performs file I/O.
Write failures create warning incidents, which prevent a clean promotion window.

## Rehearsal procedure

1. Use the exact production 64-channel HD96/Dante input, isolated encoder output, and
   96 kHz route.
2. Note the UTC start time, enable SHADOW, and run the complete service rehearsal.
3. Keep SAFE and FREEZE available, but leave them released for the candidate
   comparison except for deliberate safety checks.
4. Confirm the expected sermon or worship scene occurs, active inputs are present,
   and candidate moves are visible.
5. Note the UTC completion time, disable SHADOW, wait for the Automation status to
   change from **finalizing** to **saved**, click **Reveal**, and copy the resulting
   JSONL file into the immutable evidence directory.
6. Compare the candidate behavior with the approved operator mix and record every
   blocking issue before setting `operatorComparisonCompleted`.

Enter the exact capture window as `shadowRehearsal.startedAtUTC` and
`shadowRehearsal.completedAtUTC` in `rollout-observation.json`.

## Semantic gate

Production acceptance invokes:

```sh
/usr/bin/xcrun swift scripts/verify-shadow-decision-evidence.swift \
  --log "/proof/shadow-decisions.jsonl" \
  --expected-phase sermon \
  --window-start-ms 1785081480000 \
  --window-end-ms 1785081600000
```

The verifier decodes every line and requires one continuous session, strictly ordered
timestamps, no gap over five seconds, at least 95% coverage of the reported window,
the expected scene, active input, observable program output, a measurable change in
candidate automation state, and at least 90% of snapshots with SAFE and FREEZE
released. Every record must prove 64 channels at 96 kHz on an explicitly identified,
non-simulated HD96/Dante production input and isolated stream-facing output (a
distinct output or an identified stream/aggregate/virtual single route), with bounded
finite arrays and `programAutomationApplied: false`.

A copied replay log, simulated route, short fragment, concatenated sessions,
timestamp rewrite, frozen candidate, silent capture, or arbitrary non-empty file
cannot satisfy the rollout gate. This machine check complements—rather than
replaces—the named operator's complete-service comparison.
