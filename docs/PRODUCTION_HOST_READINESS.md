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
BUILD_METADATA="/Volumes/AutoMix Proof/Release/build-metadata.json"
FAILOVER_READINESS="$EVIDENCE_ROOT/failover-controller-readiness.json"
FAILOVER_SIGNATURE="${FAILOVER_READINESS}.sig"
FAILOVER_TRUSTED_SIGNERS="/Library/Application Support/AutoMix Native/failover-controller-allowed-signers"

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

On the separately powered failover controller, generate its readiness handoff using
the exact value returned by `hostname` on the AutoMix Mac:

```sh
sudo /usr/bin/python3 \
  /usr/local/libexec/automix-failover/audit_failover_controller.py \
  --primary-hostname "AUTOMIX-MAC-HOSTNAME" \
  --output /var/lib/automix-failover/controller-readiness.json \
  --replace
```

During initial controller provisioning, enroll its public key on the Mac through an
independently authenticated management session. The file is a dedicated trust root
containing exactly one controller identity; do not put operator acceptance keys in
it:

```sh
CONTROLLER_PUBLIC_KEY="$(ssh FAILOVER-CONTROLLER \
  sudo /bin/cat /etc/automix-failover/readiness-signing-key.pub)"
sudo /bin/mkdir -p "/Library/Application Support/AutoMix Native"
printf 'automix-failover-controller %s\n' "$CONTROLLER_PUBLIC_KEY" \
  | sudo /usr/bin/tee "$FAILOVER_TRUSTED_SIGNERS" >/dev/null
sudo /bin/chown root:wheel "$FAILOVER_TRUSTED_SIGNERS"
sudo /bin/chmod 644 "$FAILOVER_TRUSTED_SIGNERS"
```

Never transfer `/etc/automix-failover/readiness-signing-key`.

Copy the fresh report and detached signature to `$FAILOVER_READINESS` and
`$FAILOVER_SIGNATURE` over the isolated management network. Keep both owner-only
(`0600`). One safe pattern is:

```sh
ssh FAILOVER-CONTROLLER \
  sudo /bin/cat /var/lib/automix-failover/controller-readiness.json \
  > "$FAILOVER_READINESS"
ssh FAILOVER-CONTROLLER \
  sudo /bin/cat /var/lib/automix-failover/controller-readiness.json.sig \
  > "$FAILOVER_SIGNATURE"
chmod 600 "$FAILOVER_READINESS" "$FAILOVER_SIGNATURE"
```

Generate the Mac report within 15 minutes.

Then run the consolidated audit with the exact generated files:

```sh
python3 scripts/audit-production-host-readiness.py \
  --phase sermon \
  --app "/Applications/AutoMix Native.app" \
  --build-metadata "$BUILD_METADATA" \
  --inventory "$EVIDENCE_ROOT/automix-core-audio-device-inventory-YYYYMMDD-HHMMSS.json" \
  --preflight "$EVIDENCE_ROOT/automix-core-audio-preflight-YYYYMMDD-HHMMSS.json" \
  --profile "$PROFILE" \
  --failover-readiness "$FAILOVER_READINESS" \
  --failover-readiness-signature "$FAILOVER_SIGNATURE" \
  --failover-trusted-signers "$FAILOVER_TRUSTED_SIGNERS" \
  --recording-root "/Volumes/AutoMix Proof" \
  --output "$EVIDENCE_ROOT/automix-production-host-readiness.json"
```

The default production contract is fixed at 64 inputs, 96 kHz, a 7,200-second proof
window, and 20 GiB of reserve. For 32-bit float raw inputs plus stereo program, that
requires approximately 190 GiB of writable free space before filesystem overhead and
other evidence attachments.

## Fail-closed checks

The report requires all twelve checks to pass:

1. The exact clean source commit is published to `origin/main`.
2. The supplied app is an executable Developer ID build with Hardened Runtime,
   production audio-input entitlement, no debugger entitlement, an intact signature,
   stapled notarization ticket, and Gatekeeper acceptance. Its code-signature
   envelope must contain `AutoMixReleaseProvenance.plist`, and the untouched release
   `build-metadata.json` must bind that signed source commit and the exact executable
   SHA-256.
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
9. A readiness report generated within the last 15 minutes on a differently named
   controller carries a valid SSH signature from the one dedicated trusted
   `automix-failover-controller` Ed25519 key. Its signed contents prove that the
   strict config validates, its installed supervisor, audit tool, and systemd unit
   are root-owned and match the current published repository files, the hardened
   service is enabled/running with no pending daemon reload, and a status sample no
   more than two seconds old confirms that the physical relay is latched to backup.
10. OBS Studio and its bundled WebSocket plugin are signed and Gatekeeper-accepted.
11. The loopback OBS observer returns fresh production-eligible health for the exact
   streaming input/track with authenticated, advancing, clean encoder counters.
12. The token-free remote `/health` endpoint returns fresh production-eligible HLS
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

Ready reports bind the source commit and SHA-256 hashes of the app binary, release
metadata, signed in-app provenance, inventory, preflight, and venue profile. They
also bind the transferred failover-controller readiness report, its detached
signature, and the dedicated controller trust root. They expire after 15 minutes
when used by the staged runner. Verification rechecks every file binding, SSH
signature, provenance relationship, controller/package/relay state, route,
free-space measurement, Keychain/LaunchAgent state, and live observer instead of
trusting edited booleans:

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

The host audit requires that dedicated trust file to remain root-owned and
non-writable by group/world. The runner copies the verified host report plus the
failover-controller report,
signature, trust root, and every SHA-256 into the phase evidence directory. Short
`REHEARSAL_ONLY=1` engineering runs may omit them but print an
explicit warning and can never mint production proof. The staged runner and signed
acceptance verifiers remain the authoritative proof gates.
