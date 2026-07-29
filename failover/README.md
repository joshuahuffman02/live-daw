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

## Production installation

Use a dedicated Linux/systemd controller that does not share the AutoMix Mac's
power, network path, or operating system. Copy this directory and provide the
relay bearer token in a private `0600` file:

```bash
sudo ./install-systemd-service.sh \
  --heartbeat-url http://AUTOMIX-HOST:8420/health \
  --relay-url https://FAILOVER-RELAY.local/v1/selection \
  --relay-token-file /private/relay-token
```

The installer validates the URL/timing/credential contract before changing the
host, creates the unprivileged `automix-failover` user, installs a root-owned,
non-daemon-writable configuration and token, and enables
`automix-failover.service`. systemd supplies both private files as read-only
credentials; the daemon never owns or receives write access to its production
configuration.

The unit uses `Restart=always`, a 250 ms restart delay, owner-only runtime/state
directories, an empty capability set, `NoNewPrivileges`, a read-only system
filesystem, restricted address families/namespaces, and other systemd sandboxing.
Every start performs `check-config`, commands backup before polling AutoMix, and
fails installation readiness unless the relay positively confirms a fresh latched
backup state. If confirmation fails, the service remains running and continues
requesting backup, but the installer exits nonzero.

The installed private config is
`/etc/automix-failover/supervisor.json`. It is a strict versioned JSON contract;
unknown/missing fields, insecure HTTP relay URLs, unsafe timing, relative runtime
paths, symlinks, broad permissions, and invalid credentials are rejected. The
relay token is stored separately and never appears in the unit, config, process
arguments, or validation output.

Defaults are:

- health poll: 250 ms;
- health timeout: 500 ms;
- relay timeout: 500 ms;
- primary lease: 1500 ms;
- manual-return proof: three advancing healthy samples;
- control socket: `/run/automix-failover/control.sock`;
- status: `/run/automix-failover/status.json`;
- durable event journal: `/var/lib/automix-failover/events.jsonl`.

For packaging/CI without modifying a host, add
`--render-root /absolute/staging/directory`. This renders the exact filesystem
payload but does not create a user or call systemd. Direct CLI supervision remains
available for development and deterministic tests; production uses the private
config and hardened service.

## Operator commands

Read the current state:

```bash
sudo /usr/bin/python3 \
  /usr/local/libexec/automix-failover/automix_failover_supervisor.py status \
  --status-path /run/automix-failover/status.json
```

After correcting a fault and listening to both paths, deliberately return to primary:

```bash
sudo /usr/bin/python3 \
  /usr/local/libexec/automix-failover/automix_failover_supervisor.py return-primary \
  --control-socket /run/automix-failover/control.sock
```

The return command exits nonzero unless the running supervisor has current health
proof and the relay confirms primary selection. It cannot clear the latch by editing
the status file; the status file is output only.

## Verify

```bash
python3 test_automix_failover_supervisor.py
```

The 30-test deterministic suite covers heartbeat
schema/freshness/progression, HTTP failure and redirects,
startup/restart/shutdown defaults, manual-return gating, primary lease failure,
relay acknowledgement binding, private credentials/control/status, strict
production configuration, hardened systemd payload rendering, and the end-to-end
supervisor state machine.

These tests verify software behavior only. Before go-live, run and record every real
kill test in `docs/EXTERNAL_FAILOVER.md`, including power removal from the AutoMix
Mac and from the supervisor controller. Verify backup selection in at most two
seconds using the selected encoder output—not just relay status.
