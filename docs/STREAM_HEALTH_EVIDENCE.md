# Stream Health Evidence

The staged runner observes two independent endpoints for the entire hardware check:

- `encoder`: the local encoder/sidecar ingest state;
- `egress`: independently observed public platform/CDN playback.

Each endpoint is polled every two seconds with a three-second request timeout. The
live runner marks the exercise failed after two consecutive bad observations. After
the app exits, the stricter evidence verifier requires every persisted observation
to be healthy; a transient failure therefore remains visible and blocks promotion
until reviewed and rerun.

## Persisted TSV contract

`stream-health-observations.tsv` has this exact header:

```text
checkedAtMs	probe	state	responseTimestampMs	ageMs	healthy	streaming	audioActive	detail
```

Every data row must contain exactly nine tab-separated fields:

| Field | Contract |
| --- | --- |
| `checkedAtMs` | Epoch milliseconds when the request began |
| `probe` | Exactly `encoder` or `egress` |
| `state` | `healthy` |
| `responseTimestampMs` | Endpoint payload timestamp in epoch milliseconds |
| `ageMs` | Exactly `checkedAtMs - responseTimestampMs`, from −5,000 through 15,000 |
| `healthy` | `true` |
| `streaming` | `true` |
| `audioActive` | `true` |
| `detail` | Non-empty observation detail |

For each probe, timestamps must be strictly increasing, no adjacent observations may
be more than 7,000 ms apart, and at least two observations are required. The span
from first to last observation must cover at least 95% of
`soundcheckSeconds + stabilitySeconds` from the exact full-check manifest. The
manifest must report `hardwareProofPassed: true`, must match the selected sermon or
worship phase, and production acceptance requires at least 7,200 stability seconds.

Verify a log directly with:

```sh
./scripts/verify-stream-health-evidence.sh \
  --stream-health "/proof/stream-health-observations.tsv" \
  --manifest "/proof/automix-core-audio-full-check.json" \
  --expected-phase sermon \
  --require-production-duration
```

`run-staged-hardware-proof.sh` runs this after the hardware check.
`record-proof-acceptance.sh` runs it before signing, and
`verify-proof-acceptance.sh` runs it again from the signed evidence index. Changing
the log or manifest after signing also fails the outer SHA-256 contract.

The deterministic rejection suite is `scripts/test-stream-health-evidence.sh`.
