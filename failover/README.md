# Independent failover supervisor

`automix_failover_supervisor.py` is the reference controller for the external
primary/backup audio switch described in
[`../docs/EXTERNAL_FAILOVER.md`](../docs/EXTERNAL_FAILOVER.md). It is deliberately
separate from the AutoMix process and uses only the Python 3 standard library.

This software closes the controller/state-machine gap. It does **not** turn an
ordinary network relay into a fail-safe device. Production still requires a relay or
encoder input switch whose unpowered state is backup and whose primary selection
expires unless a short lease is continuously renewed.

## Safety behavior

- Every process start and clean shutdown commands and latches backup.
- AutoMix must return HTTP 200 with the exact versioned heartbeat contract.
- Heartbeat time, both callback ages, engine state, route state, stream state, and
  audio state must all be healthy.
- Heartbeat timestamps must be fresh and strictly advance. Any invalid response
  resets the proof streak.
- Healthy samples while backup is selected never cause an automatic return.
- `return-primary` is accepted only after three recent advancing healthy samples and
  a positive relay acknowledgement.
- Primary is a renewable 1.5-second lease, refreshed after every successful health
  poll. A failed refresh immediately latches backup and stops issuing primary
  commands.
- A monotonic renewal-deadline watchdog prevents a paused, blocked, or resumed
  supervisor from reasserting primary after the hardware lease may have expired.
- Operator requests are timestamped and must postdate the current backup latch, so
  a command queued before a fault cannot clear the new latch after the process
  resumes.
- The poll interval is bounded to 100–500 ms and both HTTP timeouts are bounded to
  one second. The complete worst-case renewal budget must remain shorter than the
  primary lease or the supervisor refuses to start.
- Status and incident files are atomically written with owner-only permissions. The
  operator control socket and its parent directory are owner-only.
- HTTP redirects, URL-embedded credentials, oversized bodies, unknown versions,
  malformed acknowledgements, and bearer-token files with broad permissions fail
  closed. Safety HTTP requests ignore ambient proxy environment variables.

The controller must run on hardware that does not share the AutoMix Mac's power,
network path, or operating system failure domain. Put the relay and controller on a
UPS. The backup audio path must remain independent of both.

## Relay HTTP contract

The relay adapter receives `POST` requests. A primary request looks like:

```json
{
  "formatVersion": 1,
  "kind": "automix-failover-selection",
  "requestId": "b32d2fef-a4b1-4674-8284-a43c5a870ed8",
  "issuedAtMs": 1785261600000,
  "selectedInput": "primary",
  "leaseMs": 1500,
  "latch": false,
  "manualReturnRequired": true,
  "reason": "explicit operator return after renewed health proof"
}
```

A backup request uses `selectedInput: "backup"`, `leaseMs: 0`, and `latch: true`.
The relay must reply with HTTP 2xx and:

```json
{
  "formatVersion": 1,
  "kind": "automix-failover-selection-ack",
  "requestId": "b32d2fef-a4b1-4674-8284-a43c5a870ed8",
  "ok": true,
  "selectedInput": "primary",
  "latched": false
}
```

The relay implementation must:

1. physically default to backup when unpowered;
2. start in backup after every reboot;
3. treat backup as a latched command;
4. energize primary only until the requested lease expires;
5. use its own monotonic clock for lease expiry;
6. never extend a lease for a malformed, stale, replayed, or unauthorized request;
7. confirm the physical selected-input feedback, not merely receipt of the command;
8. drop to backup when primary digital carrier/clock is absent, even if a software
   lease remains;
9. expose selected-input feedback to the venue alarm/monitoring system.

Use HTTPS and `--relay-bearer-token-file` when the relay supports them. The token
file must be a regular file with mode `0600`; the token is re-read on each request so
it can be rotated without placing it in the process arguments. Keep both endpoints
on an isolated management network.

## Run

Install this directory on the independent controller, create a dedicated
`automix-failover` operating-system user, and run the supervisor under that
controller's service manager with restart enabled:

```bash
python3 automix_failover_supervisor.py supervise \
  --heartbeat-url http://AUTOMIX-HOST:8420/health \
  --relay-url https://FAILOVER-RELAY.local/v1/selection \
  --relay-bearer-token-file /etc/automix-failover/relay-token
```

Defaults are:

- health poll: 250 ms;
- health timeout: 500 ms;
- relay timeout: 500 ms;
- primary lease: 1500 ms;
- manual-return proof: three advancing healthy samples;
- control socket: `/var/tmp/automix-failover/control.sock`;
- status: `/var/tmp/automix-failover/status.json`;
- durable event journal: `/var/tmp/automix-failover/events.jsonl`.

The service manager should alarm on process exit or a stale status timestamp. A
stopped supervisor is nevertheless safe because the relay's primary lease expires
and its physical default is backup.

## Operator commands

Read the current state:

```bash
python3 automix_failover_supervisor.py status
```

After correcting a fault and listening to both paths, deliberately return to primary:

```bash
python3 automix_failover_supervisor.py return-primary
```

The return command exits nonzero unless the running supervisor has current health
proof and the relay confirms primary selection. It cannot clear the latch by editing
the status file; the status file is output only.

## Verify

```bash
python3 test_automix_failover_supervisor.py
```

The deterministic suite covers heartbeat schema/freshness/progression, HTTP failure
and redirects, startup/restart/shutdown defaults, manual-return gating, primary lease
failure, relay acknowledgement binding, private credentials/control/status, and the
end-to-end supervisor state machine.

These tests verify software behavior only. Before go-live, run and record every real
kill test in `docs/EXTERNAL_FAILOVER.md`, including power removal from the AutoMix
Mac and from the supervisor controller. Verify backup selection in at most two
seconds using the selected encoder output—not just relay status.
