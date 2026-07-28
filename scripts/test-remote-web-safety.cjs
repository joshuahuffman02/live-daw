"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  TelemetryFreshness,
  commandPayload,
  isTelemetrySnapshot
} = require("../native/AutoMixNative/RemoteWeb/safety.js");

function snapshot(ts) {
  return {
    ts,
    venueName: "venue",
    isRunning: true,
    safe: false,
    freeze: false,
    watchdogSafe: false,
    scene: "worship",
    sampleRate: 96000,
    inputChannelCount: 64,
    bpm: 120,
    bpmConfidence: 0.8,
    stream: {
      l: -8,
      r: -8,
      momentaryLufs: -14,
      shortLufs: -14,
      integratedLufs: -14,
      limiterGrDb: -1
    },
    counters: {
      dropouts: 0,
      callbackOverruns: 0,
      deadlineMisses: 0,
      outputUnderruns: 0,
      outputOverruns: 0,
      lastCallbackFrames: 256,
      maxCallbackFrames: 256
    },
    pipeline: {
      primaryHeartbeatState: "healthy",
      primaryHeartbeatDetail: "primary audio carrier healthy",
      encoderState: "healthy",
      encoderDetail: "encoder connected",
      egressState: "healthy",
      egressDetail: "stream reachable"
    },
    scenes: [],
    channels: [],
    alerts: [],
    fault: false,
    severity: "none"
  };
}

test("an advancing telemetry timestamp keeps control fresh", () => {
  const gate = new TelemetryFreshness(1500);
  assert.equal(gate.observe(1000, 0), false);
  assert.equal(gate.observe(1100, 1400), true);
  assert.equal(gate.isFresh(2900), true);
});

test("duplicate SSE frames cannot conceal a stalled producer", () => {
  const gate = new TelemetryFreshness(1500);
  assert.equal(gate.observe(1000, 0), false);
  assert.equal(gate.observe(1000, 1400), false);
  assert.equal(gate.observe(1000, 1501), false);
});

test("a timestamp moving backward locks control and requires a new baseline", () => {
  const gate = new TelemetryFreshness(1500);
  assert.equal(gate.observe(1000, 0), false);
  assert.equal(gate.observe(1100, 1), true);
  assert.equal(gate.observe(900, 2), false);
  assert.equal(gate.observe(901, 3), false);
  assert.equal(gate.observe(902, 4), true);
});

test("transport loss locks control and two advancing frames restore it", () => {
  const gate = new TelemetryFreshness(1500);
  assert.equal(gate.observe(1000, 0), false);
  assert.equal(gate.observe(1100, 1), true);
  gate.markTransportUnavailable();
  assert.equal(gate.isFresh(2), false);
  assert.equal(gate.observe(1100, 3), false);
  assert.equal(gate.observe(1200, 4), true);
});

test("invalid telemetry never unlocks control", () => {
  const gate = new TelemetryFreshness();
  assert.equal(gate.observe(Number.NaN, 0), false);
  assert.equal(isTelemetrySnapshot(snapshot(1000)), true);
  assert.equal(isTelemetrySnapshot({ ts: 1000, channels: [] }), false);
  assert.equal(isTelemetrySnapshot(snapshot(Number.NaN)), false);
  assert.equal(isTelemetrySnapshot({ ...snapshot(1000), watchdogSafe: "false" }), false);
  assert.equal(isTelemetrySnapshot({
    ...snapshot(1000),
    alerts: [{ id: "bad", severity: "critical", title: "Bad", detail: "Bad" }]
  }), false);
  assert.equal(isTelemetrySnapshot({ ...snapshot(1000), severity: "unknown" }), false);
  assert.equal(isTelemetrySnapshot({
    ...snapshot(1000),
    pipeline: { ...snapshot(1000).pipeline, encoderState: "unknown" }
  }), false);
});

test("every command is bound to the snapshot the operator saw", () => {
  assert.deepEqual(
    commandPayload({ type: "setScene", scene: "sermon" }, 1234),
    { type: "setScene", scene: "sermon", snapshotTs: 1234 }
  );
  assert.deepEqual(
    commandPayload({
      type: "setSafe",
      on: false,
      confirmSafeRelease: true
    }, 1234),
    {
      type: "setSafe",
      on: false,
      confirmSafeRelease: true,
      snapshotTs: 1234
    }
  );
  assert.throws(
    () => commandPayload({ type: "setSafe", on: true }, Number.NaN),
    /fresh snapshot/
  );
});
