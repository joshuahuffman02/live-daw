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
checkedAtMs	probe	endpointPeer	observerKind	formatVersion	productionEligible	observerIdentity	softwareVersion	playbackHost	mediaSequence	decodedAudioSamples	authenticated	encoderProgressing	encoderIntervalClean	state	responseTimestampMs	ageMs	healthy	streaming	audioActive	detail
```

Every data row must contain exactly 21 tab-separated fields:

| Field | Contract |
| --- | --- |
| `checkedAtMs` | Epoch milliseconds when the request began |
| `probe` | Exactly `encoder` or `egress` |
| `endpointPeer` | Actual IP reached by cURL; IPv4 loopback for `encoder`, never loopback for `egress` |
| `observerKind` | Exact role contract: `automix-obs-encoder-health` or `automix-hls-egress-health` |
| `formatVersion` | Integer `1` |
| `productionEligible` | `true`; rehearsal or unauthenticated observers cannot mint proof |
| `observerIdentity` | Bound OBS program-input identity or stable offsite observer-site label |
| `softwareVersion` | Stable OBS Studio version or exact `ffmpeg version …` string |
| `playbackHost` | `-` for encoder; non-local public CDN/player host for egress |
| `mediaSequence` | `-` for encoder; non-negative HLS media sequence for egress |
| `decodedAudioSamples` | `-` for encoder; positive decoded sample count for egress |
| `authenticated` | `true` for encoder; `-` for egress |
| `encoderProgressing` | `true` for encoder; `-` for egress |
| `encoderIntervalClean` | `true` for encoder; `-` for egress |
| `state` | `healthy` |
| `responseTimestampMs` | Endpoint payload timestamp in epoch milliseconds |
| `ageMs` | Exactly `checkedAtMs - responseTimestampMs`, from −5,000 through 15,000 |
| `healthy` | `true` |
| `streaming` | `true` |
| `audioActive` | `true` |
| `detail` | Non-empty bounded observation detail |

For each probe, timestamps must be strictly increasing, no adjacent observations may
be more than 7,000 ms apart, response timestamps may never move backward and must
advance across the proof, the observer identity and software version must remain
constant, and at least two observations are required. The egress media sequence may
never move backward and must advance across the proof. The span from first to last
observation must cover at least 95% of
`soundcheckSeconds + stabilitySeconds` from the exact full-check manifest. The
manifest must report `hardwareProofPassed: true`, must match the selected sermon or
worship phase, and production acceptance requires at least 7,200 stability seconds.

The staged runner accepts only token-free HTTP(S) URLs at the exact `/health` path
and caps each payload at 64 KiB. Encoder health must use the local numeric loopback
bridge. Public egress health must use a remote observer endpoint; the runner compares
the actual connected peer against loopback and every address currently bound to the
production Mac, then records that peer so a local generic process cannot satisfy the
signed public-egress row by changing only the URL text.

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

Use `encoder/obs_health_bridge.py` for the local OBS probe and deploy
`egress/hls_health_bridge.py` on a separate host/network for a public HLS playback
probe. The egress observer timestamps verified CDN media-sequence advances only
after the newest segment produces a decoded audio frame; a cached playlist, finite
clip, generic web page, or playlist without decodable audio cannot satisfy this
contract. The encoder row additionally proves authenticated OBS counter progress,
clean encoder intervals, and the exact configured program-audio input. See
`encoder/README.md` and `egress/README.md`.
