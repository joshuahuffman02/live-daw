"use strict";

(function exposeRemoteSafety(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.AutoMixRemoteSafety = api;
}(typeof globalThis !== "undefined" ? globalThis : this, function makeRemoteSafety() {
  class TelemetryFreshness {
    constructor(staleAfterMs = 1500) {
      if (!(Number.isFinite(staleAfterMs) && staleAfterMs > 0)) {
        throw new TypeError("staleAfterMs must be positive");
      }
      this.staleAfterMs = staleAfterMs;
      this.lastSnapshotTs = null;
      this.lastProgressAtMs = null;
      this.transportAvailable = false;
      this.hasObservedProgress = false;
    }

    observe(snapshotTs, nowMs) {
      if (!(Number.isSafeInteger(snapshotTs) && snapshotTs > 0 &&
            Number.isFinite(nowMs) && nowMs >= 0)) {
        this.markTransportUnavailable();
        return false;
      }
      this.transportAvailable = true;
      if (this.lastSnapshotTs === null) {
        this.lastSnapshotTs = snapshotTs;
        this.lastProgressAtMs = nowMs;
      } else if (snapshotTs > this.lastSnapshotTs) {
        this.lastSnapshotTs = snapshotTs;
        this.lastProgressAtMs = nowMs;
        this.hasObservedProgress = true;
      } else if (snapshotTs < this.lastSnapshotTs) {
        this.markTransportUnavailable();
      }
      return this.isFresh(nowMs);
    }

    markTransportUnavailable() {
      this.transportAvailable = false;
      this.hasObservedProgress = false;
      this.lastSnapshotTs = null;
      this.lastProgressAtMs = null;
    }

    isFresh(nowMs) {
      if (!this.transportAvailable ||
          !this.hasObservedProgress ||
          this.lastProgressAtMs === null ||
          !Number.isFinite(nowMs) ||
          nowMs < this.lastProgressAtMs) {
        return false;
      }
      return nowMs - this.lastProgressAtMs <= this.staleAfterMs;
    }
  }

  function isTelemetrySnapshot(value) {
    const finiteFields = (object, fields) =>
      Boolean(object) && fields.every((field) => Number.isFinite(object[field]));
    const streamFields = [
      "l", "r", "momentaryLufs", "shortLufs", "integratedLufs", "limiterGrDb"
    ];
    const counterFields = [
      "dropouts", "callbackOverruns", "deadlineMisses", "outputUnderruns",
      "outputOverruns", "lastCallbackFrames", "maxCallbackFrames"
    ];
    const pipelineFields = [
      "primaryHeartbeatState", "primaryHeartbeatDetail",
      "encoderState", "encoderDetail", "egressState", "egressDetail"
    ];
    const severities = new Set(["none", "info", "warning", "critical"]);
    const healthStates = new Set(["disabled", "checking", "healthy", "unhealthy"]);
    return Boolean(
      value &&
      Number.isSafeInteger(value.ts) && value.ts > 0 &&
      typeof value.venueName === "string" &&
      typeof value.isRunning === "boolean" &&
      typeof value.safe === "boolean" &&
      typeof value.freeze === "boolean" &&
      typeof value.watchdogSafe === "boolean" &&
      typeof value.scene === "string" &&
      Number.isFinite(value.sampleRate) &&
      Number.isFinite(value.inputChannelCount) &&
      Number.isFinite(value.bpm) &&
      Number.isFinite(value.bpmConfidence) &&
      finiteFields(value.stream, streamFields) &&
      finiteFields(value.counters, counterFields) &&
      Boolean(value.pipeline) &&
      pipelineFields.every((field) => typeof value.pipeline[field] === "string") &&
      healthStates.has(value.pipeline.primaryHeartbeatState) &&
      healthStates.has(value.pipeline.encoderState) &&
      healthStates.has(value.pipeline.egressState) &&
      Array.isArray(value.scenes) &&
      value.scenes.every((scene) => typeof scene === "string") &&
      Array.isArray(value.channels) &&
      value.channels.every((channel) =>
        Number.isInteger(channel.idx) &&
        typeof channel.name === "string" &&
        typeof channel.role === "string" &&
        Number.isFinite(channel.levelDb) &&
        typeof channel.muted === "boolean" &&
        typeof channel.faderOverride === "boolean" &&
        Number.isFinite(channel.faderDb) &&
        typeof channel.panOverride === "boolean" &&
        Number.isFinite(channel.pan)
      ) &&
      Array.isArray(value.alerts) &&
      value.alerts.every((alert) =>
        typeof alert.id === "string" &&
        severities.has(alert.severity) &&
        typeof alert.title === "string" &&
        typeof alert.detail === "string" &&
        Array.isArray(alert.actions) &&
        alert.actions.every((action) => typeof action === "string")
      ) &&
      typeof value.fault === "boolean" &&
      severities.has(value.severity)
    );
  }

  function commandPayload(command, snapshotTs) {
    if (!command || typeof command !== "object" || Array.isArray(command)) {
      throw new TypeError("command must be an object");
    }
    if (!(Number.isSafeInteger(snapshotTs) && snapshotTs > 0)) {
      throw new TypeError("a fresh snapshot timestamp is required");
    }
    return { ...command, snapshotTs };
  }

  return {
    TelemetryFreshness,
    isTelemetrySnapshot,
    commandPayload
  };
}));
