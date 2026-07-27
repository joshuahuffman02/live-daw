// automix-processor.js
// Dugan-style gain-sharing automixer. Runs on the audio render thread.
// Each input is one speech mic (mono, post-strip). The shared gains always sum
// toward unity, so when one person talks their mic comes up and the others duck
// proportionally — the room-tone / noise floor stays constant with none of the
// on/off artifacts of gating. This is deterministic per-sample DSP: NO ML here.
//
// processorOptions: { channels: number }
// port messages:
//   { type: 'weights', values: number[] }   // per-channel membership multiplier (0 = out of automix)
//   { type: 'bypass', value: boolean }       // pass all mics through at unity
//   { type: 'nom', value: number }           // NOM attenuation strength 0..1 (gain-share depth)

class AutomixProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super()
    const n = (options.processorOptions && options.processorOptions.channels) || 1
    this.n = n
    this.env = new Float32Array(n)        // smoothed power per channel
    this.gain = new Float32Array(n).fill(1 / Math.max(1, n)) // smoothed applied gain
    this.weights = new Float32Array(n).fill(1)
    this.targetGain = new Float32Array(n)
    this.reportGains = Array.from({ length: n }, () => 0)
    this.report = { type: 'gains', gains: this.reportGains }
    this.bypass = false
    this.depth = 1.0

    const sr = sampleRate
    // level envelope: fast attack (~5 ms), slower release (~80 ms)
    this.aAtk = Math.exp(-1 / (0.005 * sr))
    this.aRel = Math.exp(-1 / (0.080 * sr))
    // gain smoothing (~8 ms) to avoid zipper
    this.gSmooth = Math.exp(-1 / (0.008 * sr))
    // noise floor offset keeps gains from chattering on silence ("last mic" behavior)
    this.floor = 1e-5

    this._frame = 0
    this.port.onmessage = (e) => {
      const d = e.data
      if (!d) return
      if (d.type === 'weights' && Array.isArray(d.values)) {
        for (let i = 0; i < this.n; i++) this.weights[i] = d.values[i] ?? 0
      } else if (d.type === 'bypass') {
        this.bypass = !!d.value
      } else if (d.type === 'nom') {
        this.depth = Math.max(0, Math.min(1, d.value))
      }
    }
  }

  process(inputs, outputs) {
    const out = outputs[0]
    const outL = out[0]
    const block = outL.length
    const n = this.n

    // 1) update per-channel level envelopes from this block's power
    for (let i = 0; i < n; i++) {
      const inp = inputs[i]
      let p = 0
      if (inp && inp[0]) {
        const ch = inp[0]
        for (let s = 0; s < ch.length; s++) p += ch[s] * ch[s]
        p /= ch.length
      }
      const a = p > this.env[i] ? this.aAtk : this.aRel
      this.env[i] = a * this.env[i] + (1 - a) * p
    }

    // 2) gain-sharing weights: g_i = w_i*env_i / sum(w_j*env_j)
    let total = this.floor
    for (let i = 0; i < n; i++) total += this.weights[i] * this.env[i]

    const targetGain = this.targetGain
    const active = this._activeCount()
    for (let i = 0; i < n; i++) {
      const share = (this.weights[i] * this.env[i]) / total
      // depth blends between full gain-sharing (depth=1) and flat sum (depth=0)
      const flat = this.weights[i] > 0 ? this.weights[i] / active : 0
      targetGain[i] = this.bypass ? this.weights[i] : (this.depth * share + (1 - this.depth) * flat)
    }

    // 3) apply, per-sample smoothed, summing all mics into the output
    for (let s = 0; s < block; s++) outL[s] = 0
    const gs = this.gSmooth
    for (let i = 0; i < n; i++) {
      const inp = inputs[i]
      const ch = inp && inp[0]
      let g = this.gain[i]
      const tg = targetGain[i]
      if (ch) {
        for (let s = 0; s < block; s++) {
          g = gs * g + (1 - gs) * tg
          outL[s] += g * ch[s]
        }
      } else {
        // still ramp the stored gain toward target even with no input
        for (let s = 0; s < block; s++) g = gs * g + (1 - gs) * tg
      }
      this.gain[i] = g
    }

    // mirror to any additional output channels (mono -> stereo upmix safety)
    for (let c = 1; c < out.length; c++) out[c].set(outL)

    // 4) report gains to the brain/UI ~ every 8 blocks
    if ((this._frame++ & 7) === 0) {
      for (let i = 0; i < n; i++) this.reportGains[i] = this.gain[i]
      this.port.postMessage(this.report)
    }
    return true
  }

  _activeCount() {
    let c = 0
    for (let i = 0; i < this.n; i++) if (this.weights[i] > 0) c++
    return Math.max(1, c)
  }
}

registerProcessor('automix-processor', AutomixProcessor)
