// Channel classifier. Runs at control rate on the main thread (NEVER in the audio
// path). Here it is a transparent spectral-feature nearest-prototype model so the
// demo needs no model download. In the appliance this same interface is backed by a
// small int8 CNN on log-mel spectrograms (ONNX Runtime / Core ML) trained on your
// weekly multitracks — `classify(features)` is the swap point.

import type { SourceClass } from '../types'

export interface ClsState {
  prevMag: Float32Array | null
  dutyHist: number[]
}

export interface Features {
  bands: number[] // [sub, low, lowMid, mid, highMid, high, air] fractions, sum=1
  centroid: number // 0..1 (log-mapped)
  flux: number // 0..~1 spectral change
  duty: number // 0..1 activity duty cycle
}

export function createClsState(): ClsState {
  return { prevMag: null, dutyHist: [] }
}

const BAND_EDGES = [0, 80, 250, 500, 2000, 5000, 12000, 24000] // 7 bands

export function extractFeatures(
  freqDb: Float32Array,
  sampleRate: number,
  fftSize: number,
  state: ClsState,
  active: boolean,
): Features {
  const n = freqDb.length
  const binHz = sampleRate / fftSize
  const lin = new Float32Array(n)
  for (let i = 0; i < n; i++) lin[i] = Math.pow(10, freqDb[i] / 10) // power

  const bands = new Array(7).fill(0)
  let total = 1e-12
  let cWeighted = 0
  for (let i = 1; i < n; i++) {
    const f = i * binHz
    const p = lin[i]
    total += p
    cWeighted += f * p
    for (let b = 0; b < 7; b++) {
      if (f >= BAND_EDGES[b] && f < BAND_EDGES[b + 1]) { bands[b] += p; break }
    }
  }
  for (let b = 0; b < 7; b++) bands[b] /= total
  const centroidHz = cWeighted / total
  const centroid = Math.max(0, Math.min(1, Math.log(Math.max(50, centroidHz) / 50) / Math.log(16000 / 50)))

  // spectral flux vs previous normalized magnitude
  let flux = 0
  const mag = new Float32Array(n)
  for (let i = 0; i < n; i++) mag[i] = Math.sqrt(lin[i] / total)
  if (state.prevMag) {
    for (let i = 0; i < n; i++) { const d = mag[i] - state.prevMag[i]; if (d > 0) flux += d }
  }
  state.prevMag = mag
  flux = Math.min(1, flux)

  // duty cycle over recent frames
  state.dutyHist.push(active ? 1 : 0)
  if (state.dutyHist.length > 80) state.dutyHist.shift()
  const duty = state.dutyHist.reduce((a, b) => a + b, 0) / Math.max(1, state.dutyHist.length)

  return { bands, centroid, flux, duty }
}

// prototype feature vectors per class + per-dimension weights
interface Proto { cls: SourceClass; bands: number[]; centroid: number; duty: number; flux: number }

// Prototypes calibrated from the measured feature vectors of the live sources.
// bands = [sub<80, low 80-250, lowMid 250-500, mid 500-2k, highMid 2-5k, high 5-12k, air].
const PROTOS: Proto[] = [
  { cls: 'kick',           bands: [0.95, 0.04, 0.01, 0.01, 0.00, 0.00, 0.00], centroid: 0.07, duty: 0.68, flux: 0.10 },
  { cls: 'bass',           bands: [0.84, 0.16, 0.00, 0.00, 0.00, 0.00, 0.00], centroid: 0.04, duty: 1.00, flux: 0.07 },
  { cls: 'electricGuitar', bands: [0.01, 0.77, 0.11, 0.10, 0.01, 0.00, 0.00], centroid: 0.32, duty: 1.00, flux: 0.05 },
  { cls: 'keys',           bands: [0.00, 0.23, 0.72, 0.05, 0.00, 0.00, 0.00], centroid: 0.32, duty: 1.00, flux: 0.08 },
  { cls: 'acousticGuitar', bands: [0.00, 0.00, 0.11, 0.77, 0.12, 0.00, 0.01], centroid: 0.575, duty: 1.00, flux: 0.06 },
  { cls: 'leadVocal',      bands: [0.00, 0.03, 0.12, 0.76, 0.05, 0.00, 0.00], centroid: 0.477, duty: 0.55, flux: 0.55 },
  { cls: 'bgv',            bands: [0.00, 0.01, 0.08, 0.80, 0.03, 0.00, 0.00], centroid: 0.449, duty: 0.62, flux: 0.40 },
  { cls: 'speech',         bands: [0.00, 0.01, 0.06, 0.46, 0.34, 0.04, 0.00], centroid: 0.624, duty: 0.76, flux: 0.90 },
]

// dims: 7 bands + centroid + duty + flux ; weights emphasize discriminative ones
const W_BANDS = [2.6, 2.6, 2.6, 1.3, 4.5, 1.4, 1.0] // high-mid (band 4) cleanly isolates noise-like speech
const W_CENTROID = 3.0
const W_DUTY = 2.6 // separates sustained instruments from phrased speech/vocal
const W_FLUX = 2.4 // noisy/phrased (speech, vocal) vs tonal sustained sources

export function classify(f: Features): { cls: SourceClass; confidence: number; scores: Partial<Record<SourceClass, number>> } {
  let best: SourceClass = 'unknown'
  let bestScore = -Infinity
  const raw: { cls: SourceClass; s: number }[] = []
  for (const p of PROTOS) {
    let d = 0
    for (let b = 0; b < 7; b++) { const e = f.bands[b] - p.bands[b]; d += W_BANDS[b] * e * e }
    d += W_CENTROID * (f.centroid - p.centroid) ** 2
    d += W_DUTY * (f.duty - p.duty) ** 2
    d += W_FLUX * (f.flux - p.flux) ** 2
    const s = -d
    raw.push({ cls: p.cls, s })
    if (s > bestScore) { bestScore = s; best = p.cls }
  }
  // softmax confidence (temperature tuned for separation)
  const T = 0.045
  let z = 0
  for (const r of raw) z += Math.exp(r.s / T)
  const scores: Partial<Record<SourceClass, number>> = {}
  let conf = 0
  for (const r of raw) {
    const pr = Math.exp(r.s / T) / z
    scores[r.cls] = pr
    if (r.cls === best) conf = pr
  }
  return { cls: best, confidence: conf, scores }
}
