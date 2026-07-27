// Auto-EQ. Two parts, exactly as the spec splits them:
//   1. corrective (pre-comp): data-driven — find the worst resonance in the measured
//      long-term spectrum and notch it.
//   2. voicing / tonal (post-comp): move toward the source-class target curve.
// All moves are scaled by classifier confidence and (in live mode) rate-limited by
// the brain before being ramped into the biquads.

import type { EqBand } from '../types'
import type { ClassProfile } from './targets'

export interface EqTargets {
  corr: { freq: number; gainDb: number; q: number }[]
  voice: { type: BiquadFilterType; freq: number; gainDb: number; q: number }[]
  bands: EqBand[] // for display
  resonanceHz: number | null
  notchHz: number // held notch location (so it doesn't hop between recomputes)
}

// long-term average magnitude (dB) per bin, EMA-updated by the brain
export function updateLtas(ltas: Float32Array | null, freqDb: Float32Array, alpha = 0.05): Float32Array {
  if (!ltas || ltas.length !== freqDb.length) {
    const a = new Float32Array(freqDb.length)
    a.set(freqDb)
    return a
  }
  for (let i = 0; i < ltas.length; i++) ltas[i] = (1 - alpha) * ltas[i] + alpha * freqDb[i]
  return ltas
}

// find the strongest resonant peak: bin that most exceeds a wide local average
function findResonance(ltas: Float32Array, binHz: number, loHz: number, hiHz: number) {
  const n = ltas.length
  const win = 8 // ~ +/- 8 bins local baseline
  let bestDev = 0
  let bestBin = -1
  for (let i = 2; i < n; i++) {
    const f = i * binHz
    if (f < loHz || f > hiHz) continue
    let sum = 0, c = 0
    for (let j = i - win; j <= i + win; j++) { if (j >= 0 && j < n) { sum += ltas[j]; c++ } }
    const base = sum / Math.max(1, c)
    const dev = ltas[i] - base
    if (dev > bestDev) { bestDev = dev; bestBin = i }
  }
  return { hz: bestBin > 0 ? bestBin * binHz : null, devDb: bestDev }
}

export function computeEq(
  profile: ClassProfile,
  ltas: Float32Array,
  sampleRate: number,
  fftSize: number,
  confidence: number,
  aggressiveness: number, // 1 soundcheck, ~0.5 live
  prevNotchHz: number, // currently-held notch location (0 = none)
): EqTargets {
  const binHz = sampleRate / fftSize
  const bands: EqBand[] = []

  // 1) corrective notch — only act on a clear, persistent resonance, and HOLD the
  // notch location (hysteresis) so it doesn't hop frequencies between measurements.
  const res = findResonance(ltas, binHz, 150, 6000)
  const corr: EqTargets['corr'] = [
    { freq: prevNotchHz || 500, gainDb: 0, q: 5 },
    { freq: 2000, gainDb: 0, q: 4 },
  ]
  let notchHz = prevNotchHz
  let notchGain = 0
  if (res.hz && res.devDb > 8) {
    const cut = -Math.min(5, (res.devDb - 8) * 0.6) * aggressiveness
    if (!prevNotchHz) { notchHz = res.hz; notchGain = cut }
    else {
      const oct = Math.abs(Math.log2(res.hz / prevNotchHz))
      if (res.devDb > 11) { notchHz = res.hz; notchGain = cut } // a clearly stronger resonance elsewhere — move
      else if (oct < 0.33) { notchHz = prevNotchHz * Math.pow(res.hz / prevNotchHz, 0.25); notchGain = cut } // same resonance — ease toward the peak, don't snap
      else { notchHz = prevNotchHz; notchGain = 0 } // a weak peak elsewhere — don't chase it
    }
  }
  let resonanceHz: number | null = null
  if (notchGain < -0.3 && notchHz) {
    corr[0] = { freq: notchHz, gainDb: notchGain, q: 5 }
    resonanceHz = notchHz
    bands.push({ type: 'peaking', freq: notchHz, gainDb: notchGain, q: 5, kind: 'corrective' })
  }

  // 2) voicing toward class target (scaled by a settled confidence — see brain)
  const voice: EqTargets['voice'] = []
  const conf = Math.max(0.3, confidence)
  for (let i = 0; i < 3; i++) {
    const v = profile.voicing[i]
    if (v) {
      const g = v.type === 'lowpass' ? 0 : v.gainDb * conf
      voice.push({ type: v.type, freq: v.freq, gainDb: g, q: v.q })
      if (v.type !== 'lowpass') bands.push({ type: v.type, freq: v.freq, gainDb: g, q: v.q, kind: 'voicing' })
    } else {
      voice.push({ type: 'peaking', freq: 1000 * (i + 1), gainDb: 0, q: 1 })
    }
  }

  return { corr, voice, bands, resonanceHz, notchHz }
}

// de-esser: estimate sibilance energy (5-9 kHz) relative to overall and return a
// negative high-shelf gain to ride when it's hot.
export function deEssGain(ltas: Float32Array, freqDbNow: Float32Array, binHz: number, enabled: boolean): number {
  if (!enabled) return 0
  let sib = 0, sibC = 0, tot = 0, totC = 0
  for (let i = 1; i < freqDbNow.length; i++) {
    const f = i * binHz
    const p = Math.pow(10, freqDbNow[i] / 10)
    tot += p; totC++
    if (f >= 5000 && f <= 9000) { sib += p; sibC++ }
  }
  const sibAvg = sib / Math.max(1, sibC)
  const totAvg = tot / Math.max(1, totC)
  const ratio = sibAvg / Math.max(1e-9, totAvg)
  // ratio > ~3 means sibilant; map to up to -6 dB
  if (ratio < 2) return 0
  return -Math.min(6, (ratio - 2) * 1.5)
}
