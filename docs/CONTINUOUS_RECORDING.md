# Continuous Recording

AutoMix Native can continuously capture the physical Core Audio/Dante input order plus
the final stereo stream mix. This is the forensic and replay source for autonomous-mix
review; it is separate from the bounded 10-second soundcheck proof.

The **Sessions** workspace wraps each capture in a versioned manifest, recovers legacy
capture folders, supports safe continuation/import/preview/replay preparation, and
keeps completed services available across app launches. See
[`MULTI_SESSION_RECORDING.md`](MULTI_SESSION_RECORDING.md) for the operator workflow,
browser differences, and failure-state behavior.

## File contract

- Each file is a 32-bit IEEE-float, interleaved WAV.
- Channels `1...N` are raw input channels in Core Audio/Dante order. They are captured
  before the editable mixer-channel map and before automation.
- Channels `N+1` and `N+2` are the final limited stream left and right outputs.
- A new segment is opened every 60 seconds. Segments have a unique session prefix and
  monotonically increasing `part-0001`, `part-0002`, and so on.
- The current WAV header is checkpointed about once per second. A process or power
  failure therefore leaves completed segments intact and limits stale header metadata
  in the open segment to roughly the last checkpoint interval. Payload after the last
  checkpoint may require WAV repair.
- Stopping continuous capture drains the queued audio and finalizes the open WAV before
  returning.
- A clean stop writes `.automix-session-complete.json` into the session directory.
  Retention never touches a session without that marker, so a capture left incomplete
  by a crash or storage fault remains available for repair and investigation.

The app never overwrites a prior session and never hard-deletes one. If retention is
enabled, only cleanly completed sessions older than the configured age are moved to
macOS Trash before a new capture starts. Retention is disabled by default.

## Real-time safety

Starting capture allocates a two-second, single-producer/single-consumer ring before
the recorder is armed. The Core Audio callback only copies samples into that
preallocated ring and publishes an atomic frame counter. A dedicated serial file queue
opens segments, writes samples, and checkpoints headers.

The callback never waits for disk I/O, takes a recording lock, opens a file, or
allocates memory. If storage cannot keep up for the full two-second reserve, the
recorder drops the incoming recording block and increments `Dropped Frames`; the live
mix continues. Any nonzero dropped-frame count means the recording is incomplete and
must not be treated as a trustworthy replay source.

## Storage planning

The uncompressed rate is:

`(input channels + 2 program channels) × sample rate × 4 bytes`

For a 64-input service:

| Sample rate | Data rate | 60-second segment | One hour |
| --- | ---: | ---: | ---: |
| 48 kHz | 12.67 MB/s | 0.76 GB | 45.6 GB |
| 96 kHz | 25.34 MB/s | 1.52 GB | 91.2 GB |

Use a fast local SSD with enough free space for the entire service and margin. Do not
record this payload to a network share or removable device without first proving its
sustained write behavior.

Before capture, the app calculates:

`planned recording bytes + configured minimum reserve`

using the opened route's actual input-channel count and sample rate. Capture waits
instead of arming if the volume cannot satisfy that requirement. During capture the
app rechecks free space every 30 seconds. If free space falls below the reserve, it
cleanly stops the recorder, logs a critical incident, and leaves the live mix running.

The venue profile defaults to automatic capture, a three-hour plan, a 20 GB reserve,
and disabled retention. Set the planned duration to cover the entire service plus
run-over. The four-hour hardware proof therefore needs a plan of at least four hours.

## Archival

Archival is deliberately a post-service operator workflow rather than an automatic
live transfer. After a clean stop:

1. Confirm `Dropped Frames` is zero and the completion marker exists.
2. Copy the entire session directory to the approved archive volume or object store.
3. Verify file counts and checksums before treating the archive as authoritative.
4. Only then allow the local retention window to move the original to Trash.

Automatic upload during a live service is avoided because it can contend for disk and
network bandwidth with the recorder and encoder.

## Operator workflow

1. Before the service, set planned duration, minimum reserve, and the optional
   retention age. Confirm **Storage** reports the planned capture fits.
2. Leave **Automatically record when the engine starts** enabled, then start and verify
   the Core Audio route. The app creates a unique session folder after the capacity
   gate passes. An operator can also request capture manually.
3. Confirm `State` is `recording`, `Captured` advances, `Segments` is nonzero, and
   `Dropped Frames` remains zero.
4. Stop capture after the service. Wait for the stop action to return before removing
   storage or quitting the app.
5. Keep the session folder together when using the files for replay evaluation.

The library's **Continue as new capture** action never reopens an old segment. It
creates a new linked session so a crash-recovered or completed capture cannot be
overwritten.

Continuous capture and the bounded soundcheck recorder are mutually exclusive. A
stability monitor may run while continuous capture is active.

## Headless hardware-proof workflow

`scripts/run-staged-hardware-proof.sh` passes `--continuous-recording` to the same
headless Core Audio stability run used for the two-hour proof. This keeps stability
measurement and the expected multitrack recording in one process and on one exact
route. Production mode first requires the fresh host-readiness report from
`PRODUCTION_HOST_READINESS.md`; its capacity check must be bound to the same
filesystem volume that receives the staged evidence.

Before opening the recorder, the command calculates the planned
`input channels + program L/R` requirement and requires that amount plus
`RECORDING_RESERVE_GB` (20 GB by default). It rechecks available capacity every
30 seconds and stops the proof if the reserve is crossed.

After the deliberate recorder stop, the file queue is drained and every segment is
re-opened. `continuous-recording-proof.json` records and verifies:

- the isolated input/output route and real-vs-simulated validation source;
- available, required, and minimum observed free bytes;
- requested and observed duration;
- captured and dropped frame counts;
- the exact sorted segment index;
- IEEE-float format, 96 kHz rate, 66-channel layout, header/file byte agreement, and
  persisted-frame agreement for every WAV;
- whether the recorder stopped before the requested window.

The report can be checked again without scanning the sample payloads:

```sh
"/Applications/AutoMix Native.app/Contents/MacOS/AutoMix Native" \
  --smoke-test \
  --verify-continuous-recording \
  --recording-report "/Volumes/Proof/AutoMix/.../continuous-recording-proof.json" \
  --require-production-duration
```

The final flag additionally requires a real isolated 64-input/96 kHz route and at
least 7,200 seconds of wall-clock and persisted recording. Short runs can exercise
the recorder, but cannot produce `productionProofPassed=true`.
