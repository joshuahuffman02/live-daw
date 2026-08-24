# Release Checklist

How a Live DAW release goes from code to a signed, evidence-backed build.
The evidence discipline exists so every production claim about the appliance
can be traced to a reproducible point in history.

## 1. Tag the release point

```bash
git tag -a vX.Y.Z -m "Release X.Y.Z"
```

All evidence produced afterwards references this commit. CI (`.github/workflows/`)
must be green on the tagged commit across all three layers: failover controller
(Ubuntu) and DSP / web / native suites (macOS).

## 2. Build and notarize the native appliance

```bash
scripts/build-notarized-release.sh
```

Produces the notarized macOS app bundle for Apple Silicon hosts.

## 3. Produce production evidence

```bash
scripts/new-production-evidence-drafts.sh     # scaffold evidence drafts
scripts/finalize-production-evidence.sh      # finalize + sign the bundle
```

Supporting evidence tooling:

| Script | Purpose |
|---|---|
| `record-runtime-incident-evidence.sh` | Capture runtime incident journal entries |
| `verify-production-evidence.sh` | Verify a finalized evidence bundle |
| `verify-stream-health-evidence.sh` | Verify stream-health gate evidence |
| `verify-shadow-decision-evidence.swift` | Verify automix shadow-mode decisions |
| `audit-production-host-readiness.py` | Audit the target host before deploy |

Finalized bundles live under `validation-artifacts/` (e.g.
`current-host-readiness/`), one directory per release/gate, never edited after
signing.

## 4. Pre-deploy verification

1. `scripts/audit-production-host-readiness.py` passes on the target Mac
2. Failover readiness evidence is present and independently signed
3. Runtime incident journal shows no unresolved gates from the previous release

## 5. After release

- Record any runtime incidents via `record-runtime-incident-evidence.sh`
- Open the next release's evidence drafts from the new tag
