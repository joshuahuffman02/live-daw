# Production host readiness audit

The hardware-proof runner is intentionally strict once a service run starts. Use the
read-only host audit first so a two-hour proof is not attempted with a missing route,
unsigned app, undersized recording volume, stale preflight, or unavailable observer.

This audit answers one narrow question:

> Is this production Mac provisioned to begin a real AutoMix hardware-proof run?

It does **not** prove the system is production-accepted. External failover kill tests,
measured camera-to-public-playback lip sync, the continuous zero-xrun run, supervised
service review, and signed sermon/worship acceptance still have to exist afterward.
Every report sets `notProductionAcceptance=true` and lists that remaining scope.

## Inputs

Generate the inventory and preflight immediately before the audit:

```sh
APP="/Applications/AutoMix Native.app/Contents/MacOS/AutoMix Native"
EVIDENCE_ROOT="/Volumes/AutoMix Proof/sermon-readiness"
PROFILE="$HOME/Library/Application Support/AutoMix Native/VenueProfile.json"

"$APP" --smoke-test --write-device-inventory \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --output-dir "$EVIDENCE_ROOT"

"$APP" --smoke-test --core-audio-preflight \
  --input-uid "DANTE_OR_AGGREGATE_INPUT_UID" \
  --output-uid "STREAM_OUTPUT_UID" \
  --expected-inputs 64 \
  --profile "$PROFILE" \
  --output-dir "$EVIDENCE_ROOT"
```

Then run the consolidated audit with the exact generated files:

```sh
python3 scripts/audit-production-host-readiness.py \
  --phase sermon \
  --app "/Applications/AutoMix Native.app" \
  --inventory "$EVIDENCE_ROOT/automix-core-audio-device-inventory-YYYYMMDD-HHMMSS.json" \
  --preflight "$EVIDENCE_ROOT/automix-core-audio-preflight-YYYYMMDD-HHMMSS.json" \
  --profile "$PROFILE" \
  --recording-root "/Volumes/AutoMix Proof" \
  --output "$EVIDENCE_ROOT/automix-production-host-readiness.json"
```

The default production contract is fixed at 64 inputs, 96 kHz, a 7,200-second proof
window, and 20 GiB of reserve. For 32-bit float raw inputs plus stereo program, that
requires approximately 190 GiB of writable free space before filesystem overhead and
other evidence attachments.

## Fail-closed checks

The report requires all eleven checks to pass:

1. The exact clean source commit is published to `origin/main`.
2. The supplied app is an executable Developer ID build with an intact signature,
   stapled notarization ticket, and Gatekeeper acceptance.
3. A fresh inventory selects a real production-eligible 64-channel input and isolated
   stream output; simulated devices cannot satisfy either side.
4. A fresh `core-audio-device` preflight is ready and bound to the inventory's exact
   selected UIDs.
5. The venue profile matches that route, 64×96 kHz policy, proof duration, continuous
   recording/reserve, and SHADOW-first sermon rollout.
6. The recording volume is writable and has enough available capacity for the whole
   proof window plus reserve.
7. Planning Center credentials exist in the app's macOS Keychain service.
8. The crash-relaunch LaunchAgent is loaded and points to the same notarized app.
9. OBS Studio and its bundled WebSocket plugin are signed and Gatekeeper-accepted.
10. The loopback OBS observer returns fresh production-eligible health for the exact
    streaming input/track with authenticated, advancing, clean encoder counters.
11. The token-free remote `/health` endpoint returns fresh production-eligible HLS
    playback evidence with an offsite identity, public playback host, media sequence,
    and decoded audio.

Inventory and preflight artifacts older than 24 hours are rejected by default.
Observer responses are bounded to 64 KiB, must be uncompressed JSON, and may not
redirect.
Health URLs containing credentials, query strings, or fragments are rejected and
never copied into the report. Keychain secret contents are never read or emitted.

## Output and exit behavior

The JSON report is written atomically with owner-only `0600` permissions:

- exit `0`: all host/proof-run prerequisites passed;
- exit `1`: the report was written, but one or more blockers remain;
- exit `2`: arguments or report writing were invalid.

Existing output is never overwritten without `--replace`, and symlink output targets
are rejected. `--skip-network-probes` is available for offline diagnostics, but both
observer checks remain failed; it can never produce a ready report.

Ready reports bind the source commit and SHA-256 hashes of the app binary, inventory,
preflight, and venue profile. They expire after 15 minutes when used by the staged
runner. Verification rechecks every file binding, signature, route, free-space
measurement, Keychain/LaunchAgent state, and live observer instead of trusting edited
booleans:

```sh
python3 scripts/audit-production-host-readiness.py \
  --verify-report "$EVIDENCE_ROOT/automix-production-host-readiness.json"
```

Production mode in `scripts/run-staged-hardware-proof.sh` requires the report and
also binds it to that run's phase, app, profile, selected input/output UIDs,
duration/reserve, and recording volume:

```sh
HOST_READINESS_REPORT="$EVIDENCE_ROOT/automix-production-host-readiness.json" \
  scripts/run-staged-hardware-proof.sh \
  sermon "/Applications/AutoMix Native.app" \
  "DANTE_OR_AGGREGATE_INPUT_UID" "STREAM_OUTPUT_UID" \
  "$PROFILE" "$EVIDENCE_ROOT"
```

The runner copies the verified report and its SHA-256 into the phase evidence
directory. Short `REHEARSAL_ONLY=1` engineering runs may omit it but print an
explicit warning and can never mint production proof. The staged runner and signed
acceptance verifiers remain the authoritative proof gates.
