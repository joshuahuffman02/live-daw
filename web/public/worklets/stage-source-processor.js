// stage-source-processor.js
// Synthesizes one church-stage source with a distinct spectral + temporal
// signature so the demo runs with NO audio files: the classifier, auto-EQ,
// automixer and loudness meter all get real, plausibly-shaped content to react to.
// This is just the stand-in for "a Dante channel of raw audio" — not part of the
// mixing engine.
//
// processorOptions: { kind: string, seed: number, level: number }

function svfInit() { return { lp: 0, bp: 0 } }
function svf(state, x, fc, q) {
  const f = 2 * Math.sin(Math.PI * Math.min(0.45, fc / sampleRate))
  const damp = 1 / Math.max(0.5, q)
  const hp = x - state.lp - damp * state.bp
  state.bp += f * hp
  state.lp += f * state.bp
  return { lp: state.lp, bp: state.bp, hp }
}

class StageSource extends AudioWorkletProcessor {
  constructor(options) {
    super()
    const o = options.processorOptions || {}
    this.kind = o.kind || 'keys'
    this.seed = o.seed || 0
    this.level = o.level ?? 0.25
    this.muted = false
    this.sr = sampleRate
    this.t = (this.seed * 0.137) % 1 // phase offset between sources
    this.n = Math.floor(this.seed * 9973)

    this.ph = [0, 0, 0, 0, 0]
    this.f1 = svfInit(); this.f2 = svfInit(); this.f3 = svfInit()
    this.lpf = svfInit(); this.hpf = svfInit()
    this.env = 0
    this.noteTimer = 0
    this.noteIdx = this.n % 4
    // speech phrase state machine
    this.spState = 'pause'
    this.spTimer = 0.4
    this.sylPh = 0

    this.port.onmessage = (e) => {
      if (e.data && e.data.type === 'mute') this.muted = !!e.data.value
    }
  }

  rnd() {
    // xorshift-ish deterministic-ish; fine for texture
    this.n ^= this.n << 13; this.n ^= this.n >>> 17; this.n ^= this.n << 5
    return ((this.n >>> 0) / 4294967295)
  }

  noteHz(scale) { return scale[this.noteIdx % scale.length] }

  process(_inputs, outputs) {
    const out = outputs[0][0]
    const block = out.length
    if (this.muted) { out.fill(0); return true }
    const dt = 1 / this.sr

    for (let s = 0; s < block; s++) {
      let y = 0
      const k = this.kind

      if (k === 'kick') {
        this.noteTimer -= dt
        if (this.noteTimer <= 0) { this.noteTimer = 0.556; this.env = 1 }
        this.env *= Math.exp(-dt / 0.12)
        const pitch = 45 + 55 * Math.exp(-(1 - this.noteTimer / 0.556) * 30)
        this.ph[0] += pitch * dt; if (this.ph[0] > 1) this.ph[0] -= 1
        const body = Math.sin(2 * Math.PI * this.ph[0])
        const click = (this.rnd() * 2 - 1)
        const c = svf(this.lpf, click, 3500, 0.7)
        y = (body * 0.95 + c.lp * 0.25) * this.env
      } else if (k === 'bass') {
        this.noteTimer -= dt
        if (this.noteTimer <= 0) { this.noteTimer = 0.556; this.noteIdx = (this.noteIdx + 1 + (this.rnd() < 0.3 ? 1 : 0)) }
        const f = this.noteHz([41.2, 49, 55, 61.7])
        this.ph[0] += f * dt; if (this.ph[0] > 1) this.ph[0] -= 1
        this.ph[1] += 2 * f * dt; if (this.ph[1] > 1) this.ph[1] -= 1
        this.ph[2] += 3 * f * dt; if (this.ph[2] > 1) this.ph[2] -= 1
        this.env += (1 - this.env) * 0.0008
        y = (Math.sin(2 * Math.PI * this.ph[0]) + 0.4 * Math.sin(2 * Math.PI * this.ph[1]) + 0.18 * Math.sin(2 * Math.PI * this.ph[2])) * 0.5 * this.env
      } else if (k === 'electric') {
        this.noteTimer -= dt
        if (this.noteTimer <= 0) { this.noteTimer = 0.556; this.env = 1; if (this.rnd() < 0.5) this.noteIdx++ }
        this.env *= Math.exp(-dt / 0.7)
        const f = this.noteHz([110, 146.8, 164.8, 196])
        this.ph[0] += f * dt; if (this.ph[0] > 1) this.ph[0] -= 1
        let saw = 2 * this.ph[0] - 1
        saw = Math.tanh(saw * 3.0) // drive
        const hp = svf(this.hpf, saw, 130, 0.7).hp
        const lp = svf(this.lpf, hp, 3200, 0.8).lp
        y = lp * 0.5 * this.env
      } else if (k === 'acoustic') {
        this.noteTimer -= dt
        if (this.noteTimer <= 0) { this.noteTimer = 0.278; this.env = 1; this.noteIdx++ }
        this.env *= Math.exp(-dt / 0.22)
        const f = this.noteHz([196, 246.9, 293.7, 220])
        let h = 0
        for (let i = 1; i <= 6; i++) {
          this.ph[i % 5] += i * f * dt; if (this.ph[i % 5] > 1) this.ph[i % 5] -= 1
          h += (1 / i) * Math.sin(2 * Math.PI * this.ph[i % 5])
        }
        const pick = (this.rnd() * 2 - 1) * Math.exp(-(1 - this.noteTimer / 0.278) * 60)
        y = (h * 0.3 + pick * 0.3) * this.env
      } else if (k === 'keys') {
        const lfo = 1 + 0.08 * Math.sin(2 * Math.PI * 4 * (this.t))
        let c = 0
        const chord = [220, 277.2, 329.6, 392]
        for (let i = 0; i < 4; i++) {
          this.ph[i] += chord[i] * dt; if (this.ph[i] > 1) this.ph[i] -= 1
          c += Math.sin(2 * Math.PI * this.ph[i]) + 0.25 * Math.sin(4 * Math.PI * this.ph[i])
        }
        const lp = svf(this.lpf, c * 0.18, 7000, 0.7).lp
        y = lp * lfo
      } else if (k === 'leadVocal' || k === 'bgv') {
        const base = k === 'bgv' ? 262 : 196
        const lvl = k === 'bgv' ? 0.5 : 1
        this.noteTimer -= dt
        if (this.noteTimer <= 0) { this.noteTimer = 0.8; this.noteIdx++; this.gap = this.rnd() < (k === 'bgv' ? 0.4 : 0.25) }
        const vib = 1 + 0.015 * Math.sin(2 * Math.PI * 5.5 * this.t)
        const f = this.noteHz([base, base * 1.122, base * 1.26, base * 1.335]) * vib
        this.ph[0] += f * dt; if (this.ph[0] > 1) this.ph[0] -= 1
        const saw = 2 * this.ph[0] - 1
        const fr1 = svf(this.f1, saw, 700, 6).bp
        const fr2 = svf(this.f2, saw, 1150, 7).bp
        const fr3 = svf(this.f3, saw, 2600, 8).bp
        const tgt = this.gap ? 0 : 1
        this.env += (tgt - this.env) * 0.0015
        y = (fr1 * 0.5 + fr2 * 0.4 + fr3 * 0.25) * this.env * lvl * 0.6
      } else if (k === 'speech') {
        // phrase/pause state machine -> gaps make the automix duck
        this.spTimer -= dt
        if (this.spTimer <= 0) {
          if (this.spState === 'phrase') { this.spState = 'pause'; this.spTimer = 0.5 + this.rnd() * 1.1 }
          else { this.spState = 'phrase'; this.spTimer = 1.2 + this.rnd() * 1.8 }
        }
        let amp = 0
        if (this.spState === 'phrase') {
          this.sylPh += (4.5 + this.rnd() * 0.02) * dt
          const syl = 0.5 - 0.5 * Math.cos(2 * Math.PI * this.sylPh)
          amp = 0.35 + 0.65 * syl
        } else {
          this.sylPh = 0
        }
        const noise = this.rnd() * 2 - 1
        const buzz = 0  // keep band-limited noise voice stand-in
        const hp = svf(this.hpf, noise + buzz, 300, 0.8).hp
        const bp = svf(this.lpf, hp, 2400, 0.9).lp
        y = bp * amp * 0.7
      }

      this.t += dt
      out[s] = y * this.level
    }
    return true
  }
}

registerProcessor('stage-source-processor', StageSource)
