// gate-processor.js
// Downward expander / noise gate with hysteresis + a few ms of look-ahead so the
// transient isn't clipped on open. Mono in, mono out. Per-sample, no ML.
//
// The brain sets `threshold` from each channel's measured noise floor and chooses
// gate-like (high ratio) for drums/instruments vs gentle expansion for speech.
//
// port messages: { type:'params', enabled, thresholdDb, ratio, rangeDb, attackMs, releaseMs, holdMs, hystDb }

class GateProcessor extends AudioWorkletProcessor {
  constructor() {
    super()
    const sr = sampleRate
    this.sr = sr
    this.enabled = false
    this.thresholdDb = -45
    this.ratio = 2.5
    this.rangeDb = 18      // max attenuation when closed
    this.hystDb = 6
    this.hold = Math.round(0.08 * sr)
    this.atk = Math.exp(-1 / (0.003 * sr))
    this.rel = Math.exp(-1 / (0.12 * sr))
    this.detAtk = Math.exp(-1 / (0.001 * sr))
    this.detRel = Math.exp(-1 / (0.05 * sr))

    this.env = 0           // detector envelope (linear)
    this.gain = 1          // smoothed gain
    this.open = false
    this.holdCnt = 0

    // look-ahead
    this.look = Math.max(4, Math.round(0.002 * sr))
    this.dl = new Float32Array(this.look)
    this.dlPos = 0

    this._frame = 0
    this.port.onmessage = (e) => {
      const d = e.data
      if (!d || d.type !== 'params') return
      if (typeof d.enabled === 'boolean') this.enabled = d.enabled
      if (typeof d.thresholdDb === 'number') this.thresholdDb = d.thresholdDb
      if (typeof d.ratio === 'number') this.ratio = d.ratio
      if (typeof d.rangeDb === 'number') this.rangeDb = d.rangeDb
      if (typeof d.hystDb === 'number') this.hystDb = d.hystDb
      if (typeof d.attackMs === 'number') this.atk = Math.exp(-1 / ((d.attackMs / 1000) * this.sr))
      if (typeof d.releaseMs === 'number') this.rel = Math.exp(-1 / ((d.releaseMs / 1000) * this.sr))
      if (typeof d.holdMs === 'number') this.hold = Math.round((d.holdMs / 1000) * this.sr)
    }
  }

  process(inputs, outputs) {
    const inp = inputs[0]
    const out = outputs[0]
    const outCh = out[0]
    const block = outCh.length
    const inCh = inp && inp[0]

    if (!this.enabled || !inCh) {
      if (inCh) outCh.set(inCh)
      else outCh.fill(0)
      return true
    }

    const openThr = Math.pow(10, this.thresholdDb / 20)
    const closeThr = Math.pow(10, (this.thresholdDb - this.hystDb) / 20)
    const minGain = Math.pow(10, -this.rangeDb / 20)

    for (let s = 0; s < block; s++) {
      const x = inCh[s]
      const ax = Math.abs(x)
      const a = ax > this.env ? this.detAtk : this.detRel
      this.env = a * this.env + (1 - a) * ax

      if (this.env > openThr) { this.open = true; this.holdCnt = this.hold }
      else if (this.env < closeThr) {
        if (this.holdCnt > 0) this.holdCnt--
        else this.open = false
      }

      // target gain: open -> unity; closed -> expander attenuation toward minGain
      let target
      if (this.open) target = 1
      else {
        const envDb = this.env > 1e-9 ? 20 * Math.log10(this.env) : -120
        const below = this.thresholdDb - envDb
        const redDb = -Math.min(this.rangeDb, below * (this.ratio - 1))
        target = Math.max(minGain, Math.pow(10, redDb / 20))
      }
      const g = target < this.gain ? this.rel : this.atk
      this.gain = g * this.gain + (1 - g) * target

      // look-ahead: output the delayed sample with the current (forward-looking) gain
      const d = this.dl[this.dlPos]
      this.dl[this.dlPos] = x
      this.dlPos = (this.dlPos + 1) % this.look
      outCh[s] = d * this.gain
    }

    if ((this._frame++ & 7) === 0) {
      this.port.postMessage({ type: 'state', open: this.open, gainDb: 20 * Math.log10(Math.max(1e-6, this.gain)) })
    }
    return true
  }
}

registerProcessor('gate-processor', GateProcessor)
