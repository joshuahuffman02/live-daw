// loudness-processor.js
// BS.1770 / EBU R128 loudness metering + a true-peak look-ahead brickwall limiter.
// This is the master-bus safety stage. Deterministic per-sample DSP, no ML.
//
// Reports to the main thread (the supervisory UI):
//   momentary (400 ms), short-term (3 s), integrated (gated) LUFS,
//   post-limiter true-peak dBTP, limiter-input true peak, and gain reduction.
//
// port messages:
//   { type: 'config', ceilingDb, targetLufs }
//   { type: 'resetIntegrated' }
//
// NOTE: K-weighting coefficients below are the BS.1770-4 values for 48 kHz.
// The engine requests a 48 kHz AudioContext; if the OS forces another rate the
// loudness reading drifts slightly (fine for a monitor), but the limiter ceiling
// is still guaranteed by the final hard clamp.

const LOG = Math.log10 || ((x) => Math.log(x) / Math.LN10)

class Biquad {
  constructor(b0, b1, b2, a1, a2) {
    this.b0 = b0; this.b1 = b1; this.b2 = b2; this.a1 = a1; this.a2 = a2
    this.z1 = 0; this.z2 = 0
  }
  process(x) {
    // transposed direct form II
    const y = this.b0 * x + this.z1
    this.z1 = this.b1 * x - this.a1 * y + this.z2
    this.z2 = this.b2 * x - this.a2 * y
    return y
  }
}

function makeKWeight() {
  // stage 1: high-shelf "head" filter; stage 2: RLB high-pass (48 kHz)
  return [
    new Biquad(1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585),
    new Biquad(1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621),
  ]
}

class LoudnessProcessor extends AudioWorkletProcessor {
  constructor() {
    super()
    const sr = sampleRate
    this.sr = sr
    this.ceilingDb = -1.0
    this.targetLufs = -14.0
    this.ceilingLin = Math.pow(10, this.ceilingDb / 20)

    // K-weighting filters per channel (stereo)
    this.k = [makeKWeight(), makeKWeight()]

    // 100 ms block accumulator
    this.block100 = Math.round(0.1 * sr)
    this.acc = [0, 0]
    this.accN = 0
    this.hist = []          // recent 100 ms block mean-squares per channel: {ms:[l,r]}
    this.maxHist = 30       // 3 s of 100 ms blocks for short-term
    this.intBlocks = []     // momentary loudness values for gated integrated
    this.maxIntBlocks = 18000 // ~30 min cap

    // true-peak 4x oversampler (polyphase windowed-sinc, 4 phases x 8 taps)
    this.os = this._buildOversampler()
    this.tpHistL = new Float32Array(this.os.taps).fill(0)
    this.tpHistR = new Float32Array(this.os.taps).fill(0)
    this.outTpHistL = new Float32Array(this.os.taps).fill(0)
    this.outTpHistR = new Float32Array(this.os.taps).fill(0)

    // look-ahead limiter
    this.look = Math.max(8, Math.round(0.0015 * sr)) // ~1.5 ms
    this.dlL = new Float32Array(this.look)
    this.dlR = new Float32Array(this.look)
    this.gainRequest = new Float32Array(this.look).fill(1)
    this.dlPos = 0
    this.limGain = 1
    this.gRelease = Math.exp(-1 / (0.060 * sr)) // 60 ms release

    this.inputTpPeakWin = 0 // decaying limiter-input true-peak hold
    this.outputTpPeakWin = 0 // decaying post-limiter true-peak hold
    this.tpDecay = Math.exp(-1 / (0.4 * sr))

    this._frame = 0

    this.port.onmessage = (e) => {
      const d = e.data
      if (!d) return
      if (d.type === 'config') {
        if (typeof d.ceilingDb === 'number') {
          this.ceilingDb = d.ceilingDb
          this.ceilingLin = Math.pow(10, d.ceilingDb / 20)
        }
        if (typeof d.targetLufs === 'number') this.targetLufs = d.targetLufs
      } else if (d.type === 'resetIntegrated') {
        this.intBlocks = []
      }
    }
  }

  _buildOversampler() {
    const phases = 4, taps = 8
    const k = []
    for (let p = 0; p < phases; p++) {
      const ph = []
      for (let t = 0; t < taps; t++) {
        const x = (t - taps / 2 + 1) - p / phases
        // windowed sinc
        const sinc = x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x)
        const w = 0.54 - 0.46 * Math.cos((2 * Math.PI * (t + 0.5)) / taps) // Hamming
        ph.push(sinc * w)
      }
      // normalize
      let s = 0
      for (const v of ph) s += v
      for (let t = 0; t < taps; t++) ph[t] /= s
      k.push(ph)
    }
    return { phases, taps, kernels: k }
  }

  _truePeak(hist, x) {
    // push x, return max abs over 4x oversampled output for this sample
    const taps = this.os.taps
    for (let i = taps - 1; i > 0; i--) hist[i] = hist[i - 1]
    hist[0] = x
    let mx = Math.abs(x)
    for (let p = 0; p < this.os.phases; p++) {
      const ker = this.os.kernels[p]
      let y = 0
      for (let t = 0; t < taps; t++) y += ker[t] * hist[t]
      const a = Math.abs(y)
      if (a > mx) mx = a
    }
    return mx
  }

  _pushBlock() {
    const n = this.accN || 1
    const msL = this.acc[0] / n
    const msR = this.acc[1] / n
    this.hist.push([msL, msR])
    if (this.hist.length > this.maxHist) this.hist.shift()

    // momentary = last 4 blocks (400 ms)
    const m = Math.min(4, this.hist.length)
    let sL = 0, sR = 0
    for (let i = this.hist.length - m; i < this.hist.length; i++) {
      sL += this.hist[i][0]; sR += this.hist[i][1]
    }
    const momMs = sL / m + sR / m
    if (momMs > 0) {
      const momLufs = -0.691 + 10 * LOG(momMs)
      if (momLufs > -70) {
        this.intBlocks.push(momMs)
        if (this.intBlocks.length > this.maxIntBlocks) this.intBlocks.shift()
      }
    }
    this.acc[0] = 0; this.acc[1] = 0; this.accN = 0
  }

  _readout() {
    // momentary
    const m = Math.min(4, this.hist.length)
    let sL = 0, sR = 0
    for (let i = this.hist.length - m; i < this.hist.length; i++) {
      sL += this.hist[i][0]; sR += this.hist[i][1]
    }
    const momMs = m ? (sL / m + sR / m) : 0
    const mom = momMs > 0 ? -0.691 + 10 * LOG(momMs) : -100

    // short-term (3 s)
    const st = this.hist.length
    let tL = 0, tR = 0
    for (let i = 0; i < st; i++) { tL += this.hist[i][0]; tR += this.hist[i][1] }
    const stMs = st ? (tL / st + tR / st) : 0
    const short = stMs > 0 ? -0.691 + 10 * LOG(stMs) : -100

    // integrated, gated (abs -70 then relative -10 LU)
    let integ = -100
    if (this.intBlocks.length) {
      let sum = 0
      for (const v of this.intBlocks) sum += v
      const meanAll = sum / this.intBlocks.length
      const relGate = -0.691 + 10 * LOG(meanAll) - 10
      let g = 0, c = 0
      for (const v of this.intBlocks) {
        const l = -0.691 + 10 * LOG(v)
        if (l >= relGate) { g += v; c++ }
      }
      if (c) integ = -0.691 + 10 * LOG(g / c)
    }

    const inputTpDb = this.inputTpPeakWin > 0
      ? 20 * (Math.log(this.inputTpPeakWin) / Math.LN10)
      : -100
    const outputTpDb = this.outputTpPeakWin > 0
      ? 20 * (Math.log(this.outputTpPeakWin) / Math.LN10)
      : -100
    return { mom, short, integ, inputTpDb, outputTpDb }
  }

  process(inputs, outputs) {
    const inp = inputs[0]
    const out = outputs[0]
    const block = out[0].length
    const inL = (inp && inp[0]) || null
    const inR = (inp && (inp[1] || inp[0])) || null
    const outL = out[0]
    const outR = out[1] || out[0]

    for (let s = 0; s < block; s++) {
      const xL = inL ? inL[s] : 0
      const xR = inR ? inR[s] : 0

      // --- metering: K-weighted mean square ---
      const yL = this.k[0][1].process(this.k[0][0].process(xL))
      const yR = this.k[1][1].process(this.k[1][0].process(xR))
      this.acc[0] += yL * yL
      this.acc[1] += yR * yR
      if (++this.accN >= this.block100) this._pushBlock()

      // --- true-peak detection (pre-limiter signal) ---
      const tpL = this._truePeak(this.tpHistL, xL)
      const tpR = this._truePeak(this.tpHistR, xR)
      const tp = Math.max(tpL, tpR)
      this.inputTpPeakWin = Math.max(tp, this.inputTpPeakWin * this.tpDecay)

      // --- look-ahead limiter ---
      // target gain so the (oversampled) peak meets the ceiling
      let gTarget = 1
      if (tp > this.ceilingLin) gTarget = this.ceilingLin / tp

      // delayed signal out of the look-ahead buffer
      const dL = this.dlL[this.dlPos]
      const dR = this.dlR[this.dlPos]
      this.dlL[this.dlPos] = xL
      this.dlR[this.dlPos] = xR
      this.gainRequest[this.dlPos] = gTarget
      this.dlPos = (this.dlPos + 1) % this.look

      // The full look-ahead window is known before the delayed sample leaves.
      // Apply its most conservative true-peak gain request immediately, then
      // release slowly after the request leaves the window.
      let lookaheadGain = 1
      for (let i = 0; i < this.gainRequest.length; i++) {
        if (this.gainRequest[i] < lookaheadGain) {
          lookaheadGain = this.gainRequest[i]
        }
      }
      const releasedGain = this.gRelease * this.limGain + (1 - this.gRelease)
      this.limGain = Math.min(lookaheadGain, releasedGain)

      let oL = dL * this.limGain
      let oR = dR * this.limGain
      // final hard guarantee on the sample-domain peak
      const c = this.ceilingLin
      if (oL > c) oL = c; else if (oL < -c) oL = -c
      if (oR > c) oR = c; else if (oR < -c) oR = -c
      outL[s] = oL
      if (out[1]) outR[s] = oR

      const outTpL = this._truePeak(this.outTpHistL, oL)
      const outTpR = this._truePeak(this.outTpHistR, oR)
      const outTp = Math.max(outTpL, outTpR)
      this.outputTpPeakWin = Math.max(
        outTp,
        this.outputTpPeakWin * this.tpDecay,
      )
    }

    if ((this._frame++ & 3) === 0) {
      const r = this._readout()
      this.port.postMessage({
        type: 'loudness',
        momentary: r.mom,
        short: r.short,
        integrated: r.integ,
        truePeak: r.outputTpDb,
        inputTruePeak: r.inputTpDb,
        grDb: 20 * (Math.log(this.limGain) / Math.LN10),
        target: this.targetLufs,
        ceiling: this.ceilingDb,
      })
    }
    return true
  }
}

registerProcessor('loudness-processor', LoudnessProcessor)
