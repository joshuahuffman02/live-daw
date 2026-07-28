# External Audio Failover Contract

The in-app SAFE mix covers a stalled brain or a broken normal DSP path. It cannot
cover a crashed application, stopped Core Audio device, failed Mac, failed DVS
process, or loss of power. Production go-live therefore requires a second audio path
that does not depend on this application or computer.

## Required topology

1. Keep the autonomous mix as the primary encoder feed:
   `HD96 Dante split -> DVS/Mac -> AutoMix -> isolated encoder input A`.
2. Build a static broadcast-safe backup outside the Mac:
   `HD96 broadcast matrix/direct split -> hardware dynamics/limiter if needed ->
   isolated encoder input B`.
3. Put a fail-safe hardware A/B switch or encoder input-failover function after the
   two paths. Its unpowered/default state must select input B.
4. Drive primary selection with a continuously energized health output. Loss of Mac
   power, application heartbeat, DVS clock, or primary audio carrier must release the
   switch to backup. Do not depend on a command from the failing application.
5. Return from backup to primary manually after an operator verifies stable audio.
   Automatic return can flap during a partial failure and is not permitted.

The backup is broadcast-only and must never feed an HD96/FOH input. It is a curated
static mix, not a flat 64-channel sum:

- speech/pastor and playback are the highest priorities;
- lead vocal is present below speech;
- band sources are conservative and grouped;
- unused/unknown inputs are excluded;
- output has fixed headroom and a true-peak ceiling at or below -1 dBTP.

## Health and switching behavior

- Loss of the normally energized hardware heartbeat switches immediately.
- Loss of primary digital carrier/clock switches immediately.
- Sustained primary silence may switch after 2 seconds only when the backup path is
  demonstrably active; this avoids replacing intentional silence with noise.
- The switch exposes a dry contact, GPIO, or network status that the encoder/monitor
  can log, but logging is not in the switching dependency chain.
- The operator gets a latched, high-priority alarm showing that backup is active.

### Built-in primary-audio heartbeat

AutoMix exposes a read-only, token-free heartbeat when **Phone / tablet console** is
enabled:

`http://AUTOMIX-HOST:8420/health`

The Remote Monitoring panel shows the exact URL and current state. HTTP 200 is
returned only while all of these are true:

- the operator has not stopped the engine;
- the running input/output UIDs still match the configured route;
- the input is an explicitly identified, non-simulated HD96/Dante device;
- the route is exactly 64 channels at 96 kHz with an isolated stream-facing output;
- both Core Audio callbacks have started and remain under the one-second stall limit;
- the app's main control loop refreshed the heartbeat within one second.

Every response uses the same `healthy`, `streaming`, `audioActive`, and `timestampMs`
fields as the stream-health contract, plus route/callback diagnostics and
`manualReturnRequired: true`. A stopped engine, relaxed/simulated rehearsal route,
route replacement, stalled callback, or stale main loop returns HTTP 503 with all
three health booleans false. Process or Mac failure makes the URL unreachable.
Responses are `application/json` with `Cache-Control: no-store`. A healthy response
has this wire shape (timestamps and callback ages vary):

```json
{
  "formatVersion": 1,
  "kind": "automix-primary-audio-heartbeat",
  "ok": true,
  "healthy": true,
  "streaming": true,
  "audioActive": true,
  "timestampMs": 1785261600000,
  "name": "AutoMix Mac",
  "detail": "primary audio carrier healthy",
  "engineRunning": true,
  "routeHealthy": true,
  "inputCallbackAgeMs": 12.5,
  "outputCallbackAgeMs": 10.2,
  "manualReturnRequired": true
}
```

An external relay/controller must poll at least twice per second, use a connection
and response timeout no longer than one second, and treat HTTP 503, malformed/stale
data, timeout, connection refusal, DNS failure, and network loss as loss of primary.
That cadence keeps worst-case heartbeat detection inside the two-second switchover
acceptance window. The controller—not AutoMix—must latch backup and require manual
return. It must reject an unknown `kind`/`formatVersion`, require all four readiness
booleans to be true, and reject a timestamp that stops advancing. Keep this
unauthenticated read-only URL on the isolated management network; never expose the
monitor server to the public internet.

### Independent reference supervisor

The repo includes a deployable, standard-library-only reference controller at
[`failover/automix_failover_supervisor.py`](../failover/automix_failover_supervisor.py).
It runs outside AutoMix, defaults to backup on every start and shutdown, validates the
entire heartbeat contract, rejects redirects and non-advancing timestamps, and
requires three fresh advancing samples before an explicit operator return can
succeed. Healthy audio never clears the backup latch automatically.

The supervisor drives the relay through a renewable primary lease rather than a
one-time “select A” command. The default lease is 1.5 seconds. Every poll while
primary is selected must produce both a valid heartbeat and an acknowledgement
bound to the exact relay request. A failed health check or lease acknowledgement
immediately commands latched backup and stops renewing primary. If the supervisor,
its host, or its network disappears, the relay's local monotonic lease expires and
the de-energized hardware state selects backup without waiting for a failure command.
A monotonic controller watchdog also refuses to renew a lease when too little time
remains for the relay request, so a suspended or blocked controller cannot resume and
silently reassert primary after the hardware may already have selected backup.
Operator return requests are bound to their issue time and rejected when they predate
the current backup latch, preventing a command queued before a stall from clearing
the new fault state after the controller resumes.

The versioned relay request/acknowledgement contract, secure deployment rules,
status/journal paths, and operator commands are specified in
[`failover/README.md`](../failover/README.md). The deliberate return command is:

```bash
python3 automix_failover_supervisor.py return-primary
```

It is carried over an owner-only local Unix socket and is rejected unless renewed
health proof is current and the relay confirms the physical selection. Editing the
status JSON cannot change the selected path.

The endpoint makes the application-side heartbeat concrete. It does not replace the
normally de-energized relay/encoder failover, primary carrier sensing, backup mix,
or real kill tests.

## Go-live kill tests

Run every test with program audio present and record both encoder inputs plus the
selected output:

1. Force-quit AutoMix.
2. Stop the DVS/Core Audio route.
3. Unplug the Mac's Dante/network connection.
4. Remove the selected output device.
5. Power off the Mac.
6. Restore each failure while backup remains selected, then perform a deliberate
   manual return.

Acceptance criteria:

- backup becomes selected within 2 seconds;
- selected output has no silent gap longer than 2 seconds;
- no sample exceeds the agreed true-peak ceiling;
- speech remains intelligible on the backup;
- no backup or primary signal appears on any FOH return;
- the switch never oscillates between inputs;
- the incident and selected-path state are visible to the operator;
- the system remains on backup until the operator explicitly returns it.

Record the switch model, wiring diagram, encoder inputs, heartbeat mechanism, measured
switch time, peak/loudness results, and test recording in the venue profile's
validation bundle. Hardware proof is not complete until these tests pass on the real
rig. Encode the results and attachment hashes in the `external-failover` JSON
contract in `PRODUCTION_EVIDENCE_FORMAT.md`; signed acceptance rejects a free-form
or semantically failing substitute.
