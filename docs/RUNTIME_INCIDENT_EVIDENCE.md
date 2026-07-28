# Runtime Incident Evidence

AutoMix appends runtime events to:

`~/Library/Application Support/AutoMix Native/Incidents/runtime-incidents.jsonl`

Each line is one JSON object with:

```json
{
  "timestampMs": 1780000001000,
  "kind": "engine-started",
  "severity": "info",
  "message": "Core Audio engine started",
  "details": {
    "inputUID": "production-dante-input"
  }
}
```

The staged hardware runner records its wall-clock start and end, then creates
`runtime-incident-evidence.json`. The report preserves:

- the exact sermon/worship phase and full-check manifest SHA-256;
- the proof-window timestamps and capture timestamp;
- the source journal's absolute path, presence, SHA-256, byte count, and line count
  at capture time;
- every journal event whose timestamp falls in the proof window;
- independently recomputed info, warning, and critical totals.

The recorder validates every source JSONL line before producing evidence. Window
events must be timestamp ordered and have a valid kind, severity, message, and
string-keyed details object. The window must span at least 95% of the manifest's
requested soundcheck plus stability duration. Production proof additionally requires
at least 7,200 stability seconds.

Promotion permits informational lifecycle events but requires zero warning and zero
critical events. This deliberately makes recording drops, near-limit clock
correction, watchdog SAFE, route loss, automatic restart, encoder/egress failure,
and storage failures rerun conditions. Run disruptive recovery drills outside the
clean acceptance window and preserve them in the separate
`runtime-resilience` evidence report.

Planning Center plan loads and applied scenes are informational events. A supervised
service's journal snapshot can also serve as the rollout-observation cue trace:
`verify-production-evidence.sh` binds those events to the reported plan ID, plan item
count, applied cue count, and rollout timestamps. Planning Center credentials are not
logged.

The staged runner uses the standard journal path automatically. A controlled
commissioning environment may set `AUTOMIX_INCIDENT_JOURNAL_PATH` to the exact
journal being observed.

Verify a report with:

```sh
./scripts/verify-runtime-incident-evidence.sh \
  --report "/proof/runtime-incident-evidence.json" \
  --manifest "/proof/automix-core-audio-full-check.json" \
  --expected-phase sermon \
  --require-production-duration
```

`record-proof-acceptance.sh` verifies the report before signing.
`verify-proof-acceptance.sh` retrieves the exact signed report and manifest and runs
the same checks again. The deterministic recorder/verifier rejection suite is
`scripts/test-runtime-incident-evidence.sh`.
