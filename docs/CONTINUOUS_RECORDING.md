# Continuous Recording

AutoMix Native can continuously capture the physical Core Audio/Dante input order plus
the final stereo stream mix. This is the forensic and replay source for autonomous-mix
review; it is separate from the bounded 10-second soundcheck proof.

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

The app never deletes or overwrites prior sessions. Retention remains an operator
responsibility.

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
sustained write behavior. Automatic free-space gating, retention, and archive
rotation are not implemented yet.

## Operator workflow

1. Start and verify the Core Audio route.
2. In **Continuous Capture**, select **Start Continuous Recording**. The app creates a
   unique session folder under its Application Support directory.
3. Confirm `Captured` advances, `Segments` is nonzero, and `Dropped Frames` remains
   zero.
4. Stop capture after the service. Wait for the stop action to return before removing
   storage or quitting the app.
5. Keep the session folder together when using the files for replay evaluation.

Continuous capture and the bounded soundcheck recorder are mutually exclusive. A
stability monitor may run while continuous capture is active.
