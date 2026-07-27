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
rig.
