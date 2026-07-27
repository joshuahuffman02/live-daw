// Small DSP/units helpers shared by the engine and the brain.

export const dbToGain = (db: number) => Math.pow(10, db / 20)
export const gainToDb = (g: number) => (g > 1e-7 ? 20 * Math.log10(g) : -140)
export const clamp = (x: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, x))

// Smoothly ramp an AudioParam toward a value (avoids zipper noise). `tau` is the
// time constant in seconds — the spec's "audio thread ramps to the brain's target".
export function ramp(param: AudioParam, value: number, ctx: BaseAudioContext, tau = 0.05) {
  if (!isFinite(value)) return
  try {
    param.setTargetAtTime(value, ctx.currentTime, tau)
  } catch {
    param.value = value
  }
}

// rate-limit a value toward a target by at most `maxStep` per call
export function approach(current: number, target: number, maxStep: number) {
  const d = target - current
  if (Math.abs(d) <= maxStep) return target
  return current + Math.sign(d) * maxStep
}

// RMS (dBFS) of a time-domain buffer
export function rmsDb(buf: Float32Array): number {
  let s = 0
  for (let i = 0; i < buf.length; i++) s += buf[i] * buf[i]
  const r = Math.sqrt(s / buf.length)
  return r > 1e-7 ? 20 * Math.log10(r) : -140
}

// peak (dBFS)
export function peakDb(buf: Float32Array): number {
  let p = 0
  for (let i = 0; i < buf.length; i++) { const a = Math.abs(buf[i]); if (a > p) p = a }
  return p > 1e-7 ? 20 * Math.log10(p) : -140
}
