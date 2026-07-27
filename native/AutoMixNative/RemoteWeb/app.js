"use strict";

const $ = (id) => document.getElementById(id);
const SCENE_LABELS = {
  preService: "Pre-Service", worship: "Worship", sermon: "Sermon",
  prayer: "Prayer", postService: "Post-Service"
};
const sceneLabel = (s) => SCENE_LABELS[s] || (s ? s[0].toUpperCase() + s.slice(1) : s);

let token = localStorage.getItem("amtoken") || "";
let expanded = null;          // channel idx whose detail row is open
let lastSnap = null;
let activeCriticalIds = new Set();
let alarm = null;             // WebAudio alarm controller

// ---- meters ----
function dbToPct(db) { return Math.max(0, Math.min(1, (db + 80) / 80)) * 100; }
function fillClass(db) { return db > -6 ? "hot" : (db > -18 ? "warn" : ""); }
function fmtDb(db) { return db <= -99 ? "−∞" : db.toFixed(1) + " dB"; }

// ---- rendering ----
function render(s) {
  lastSnap = s;
  $("venue").textContent = s.venueName || "AutoMix";
  setConn(true);

  $("runDot").className = "dot " + (s.isRunning ? "run" : "stop");
  $("runText").textContent = s.isRunning ? "Auto mix running" : "Engine stopped";
  $("subStatus").textContent =
    `${s.safe ? "SAFE on" : "SAFE off"} · ${s.freeze ? "FREEZE on" : "FREEZE off"} · ${s.inputChannelCount} ch @ ${Math.round(s.sampleRate / 1000)}k`;

  setMeter("meterL", "dbL", s.stream.l);
  setMeter("meterR", "dbR", s.stream.r);
  $("lufs").textContent = (s.stream.integratedLufs <= -99 ? "—" : s.stream.integratedLufs.toFixed(1)) + " LUFS";
  $("gr").textContent = "lim " + (s.stream.limiterGrDb).toFixed(1) + " dB";
  $("tempo").textContent = (s.bpm >= 60)
    ? Math.round(s.bpm) + " BPM" + (s.bpmConfidence > 0.4 ? "" : "?")
    : "— BPM";
  $("drops").textContent = s.counters.dropouts + " drops";

  renderScenes(s);
  renderChannels(s);

  const safeBtn = $("safeBtn");
  safeBtn.textContent = s.safe ? "SAFE engaged — release" : "Engage SAFE";
  safeBtn.classList.toggle("engaged", s.safe);

  renderAlerts(s);
}

function setMeter(meterId, dbId, db) {
  const f = $(meterId);
  f.style.width = dbToPct(db) + "%";
  f.className = "fill " + fillClass(db);
  $(dbId).textContent = fmtDb(db);
}

function renderScenes(s) {
  const host = $("scenes");
  if (host.childElementCount !== s.scenes.length) {
    host.innerHTML = "";
    s.scenes.forEach((sc) => {
      const b = document.createElement("button");
      b.className = "pill"; b.dataset.scene = sc; b.textContent = sceneLabel(sc);
      b.onclick = () => sendCommand({ type: "setScene", scene: sc });
      host.appendChild(b);
    });
  }
  [...host.children].forEach((b) => b.classList.toggle("active", b.dataset.scene === s.scene));
}

function renderChannels(s) {
  const host = $("channels");
  host.innerHTML = "";
  s.channels.forEach((c) => {
    const row = document.createElement("div");
    row.className = "ch" + (c.muted ? " muted" : "");

    const name = document.createElement("div");
    name.className = "name"; name.textContent = c.name;
    name.onclick = () => { expanded = (expanded === c.idx ? null : c.idx); renderChannels(lastSnap); };

    const bar = document.createElement("div");
    bar.className = "chbar";
    const fill = document.createElement("div");
    fill.className = "chfill"; fill.style.width = dbToPct(c.levelDb) + "%";
    fill.style.background = c.muted ? "" : ({ "hot": "var(--red)", "warn": "var(--amber)", "": "var(--green)" }[fillClass(c.levelDb)]);
    bar.appendChild(fill);

    const mute = document.createElement("button");
    mute.className = "mutebtn" + (c.muted ? " on" : "");
    mute.textContent = c.muted ? "M" : "○";
    mute.setAttribute("aria-label", (c.muted ? "Unmute " : "Mute ") + c.name);
    mute.onclick = () => sendCommand({ type: "setMute", idx: c.idx, on: !c.muted });

    row.append(name, bar, mute);
    host.appendChild(row);

    if (expanded === c.idx) host.appendChild(channelDetail(c));
  });
}

function channelDetail(c) {
  const d = document.createElement("div");
  d.className = "chrow-detail";

  const fader = document.createElement("label");
  fader.innerHTML = `<span>Fader</span>`;
  const fIn = document.createElement("input");
  fIn.type = "range"; fIn.min = -80; fIn.max = 12; fIn.step = 0.5; fIn.value = c.faderDb;
  const fVal = document.createElement("span"); fVal.className = "val"; fVal.textContent = c.faderDb.toFixed(1);
  fIn.oninput = () => { fVal.textContent = (+fIn.value).toFixed(1); };
  fIn.onchange = () => sendCommand({ type: "setFaderOverride", idx: c.idx, on: true, db: +fIn.value });
  fader.append(fIn, fVal);

  const pan = document.createElement("label");
  pan.innerHTML = `<span>Pan</span>`;
  const pIn = document.createElement("input");
  pIn.type = "range"; pIn.min = -1; pIn.max = 1; pIn.step = 0.05; pIn.value = c.pan;
  const pVal = document.createElement("span"); pVal.className = "val"; pVal.textContent = c.pan.toFixed(2);
  pIn.oninput = () => { pVal.textContent = (+pIn.value).toFixed(2); };
  pIn.onchange = () => sendCommand({ type: "setPanOverride", idx: c.idx, on: true, pan: +pIn.value });
  pan.append(pIn, pVal);

  const clear = document.createElement("button");
  clear.textContent = "Clear overrides (back to auto)";
  clear.onclick = () => sendCommand({ type: "clearOverride", idx: c.idx });

  d.append(fader, pan, clear);
  return d;
}

// ---- alerts / alarm / notifications ----
function renderAlerts(s) {
  const fault = $("fault");
  const critical = s.alerts.filter((a) => a.severity === "critical");
  const warnings = s.alerts.filter((a) => a.severity === "warning");

  const newCritical = critical.filter((a) => !activeCriticalIds.has(a.id));
  if (newCritical.length) notify(newCritical[0]);
  activeCriticalIds = new Set(critical.map((a) => a.id));

  if (critical.length) {
    document.body.classList.add("fault");
    fault.className = "";
    fault.innerHTML = faultHTML(critical[0], true);
    fault.classList.remove("hidden");
    wireFaultActions(critical[0]);
    startAlarm();
  } else if (warnings.length) {
    document.body.classList.remove("fault");
    fault.className = "warn";
    fault.innerHTML = faultHTML(warnings[0], false);
    fault.classList.remove("hidden");
    wireFaultActions(warnings[0]);
    stopAlarm();
  } else {
    document.body.classList.remove("fault");
    fault.classList.add("hidden");
    fault.innerHTML = "";
    stopAlarm();
  }
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function faultHTML(a, critical) {
  const actions = (a.actions || []).includes("engageSafe")
    ? `<button class="primary" data-act="safe">Engage SAFE now</button>` : "";
  return `<div class="fic">⚠</div><div class="ftitle">${esc(a.title)}</div>` +
    `<div class="fdetail">${esc(a.detail)}</div>` +
    `<div class="factions">${actions}` +
    `<button class="secondary" data-act="dismiss">Dismiss · silence</button></div>`;
}

function wireFaultActions(a) {
  $("fault").querySelectorAll("button").forEach((b) => {
    b.onclick = () => {
      if (b.dataset.act === "safe") sendCommand({ type: "setSafe", on: true });
      if (b.dataset.act === "dismiss") { stopAlarm(); $("fault").classList.add("hidden"); }
    };
  });
}

function startAlarm() {
  $("alarmStop").classList.remove("hidden");
  if (alarm) return;
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const gain = ctx.createGain(); gain.gain.value = 0.0001; gain.connect(ctx.destination);
    const osc = ctx.createOscillator(); osc.type = "square"; osc.frequency.value = 880; osc.connect(gain); osc.start();
    let on = false;
    const id = setInterval(() => { on = !on; gain.gain.setTargetAtTime(on ? 0.18 : 0.0001, ctx.currentTime, 0.01); osc.frequency.value = on ? 988 : 740; }, 500);
    alarm = { stop: () => { clearInterval(id); try { osc.stop(); ctx.close(); } catch (e) {} } };
  } catch (e) { alarm = null; }
}

function stopAlarm() {
  $("alarmStop").classList.add("hidden");
  if (alarm) { alarm.stop(); alarm = null; }
}

function notify(a) {
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  const opts = { body: a.detail, tag: a.id, renotify: true, requireInteraction: true };
  navigator.serviceWorker?.ready.then((reg) => reg.showNotification("AutoMix · " + a.title, opts))
    .catch(() => { try { new Notification("AutoMix · " + a.title, opts); } catch (e) {} });
}

// ---- networking ----
function connectSSE() {
  const es = new EventSource("/events");
  es.onmessage = (e) => { try { render(JSON.parse(e.data)); } catch (err) {} };
  es.onerror = () => { setConn(false); };
}

function setConn(up) {
  const c = $("conn");
  c.textContent = up ? "linked" : "reconnecting";
  c.className = up ? "conn-up" : "conn-down";
}

async function sendCommand(cmd) {
  if (!token) { openPair(); return; }
  try {
    const res = await fetch("/command", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-AMToken": token },
      body: JSON.stringify(cmd),
      credentials: "same-origin"
    });
    if (res.status === 401) { token = ""; localStorage.removeItem("amtoken"); openPair(); }
  } catch (e) {}
}

function openPair() { $("pair").classList.remove("hidden"); }
function closePair() { $("pair").classList.add("hidden"); }

async function doPair() {
  const code = $("pairCode").value.trim();
  if (code.length !== 6) { $("pairMsg").textContent = "Enter the 6-digit code."; return; }
  try {
    const res = await fetch("/pair", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, label: navigator.platform || "device" }),
      credentials: "same-origin"
    });
    const data = await res.json();
    if (data.ok && data.token) {
      token = data.token; localStorage.setItem("amtoken", token);
      $("pairMsg").textContent = "";
      closePair();
      if ("Notification" in window && Notification.permission === "default") Notification.requestPermission();
    } else {
      $("pairMsg").textContent = "Wrong code — check the Mac.";
    }
  } catch (e) { $("pairMsg").textContent = "Could not reach the Mac."; }
}

// ---- boot ----
function boot() {
  $("main").classList.remove("hidden");
  $("footer").classList.remove("hidden");
  $("safeBtn").onclick = () => sendCommand({ type: "setSafe", on: !(lastSnap && lastSnap.safe) });
  $("pairBtn").onclick = doPair;
  $("pairSkip").onclick = closePair;
  $("alarmStop").onclick = () => stopAlarm();
  connectSSE();
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
}

boot();
