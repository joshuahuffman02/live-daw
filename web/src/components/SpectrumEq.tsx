import { useEffect, useRef } from 'react'
import type { EqBand } from '../types'

// Live spectrum (filled) with the brain's current EQ curve overlaid. The spectrum
// reads the post-strip analyser directly; the EQ curve is drawn from the channel's
// active bands so you can see WHAT the AI is doing to the tone.
export default function SpectrumEq({
  analyser, bands, width = 150, height = 56,
}: {
  analyser: AnalyserNode
  bands: EqBand[]
  width?: number
  height?: number
}) {
  const ref = useRef<HTMLCanvasElement>(null)
  const bandsRef = useRef(bands)
  bandsRef.current = bands
  const buf = useRef(new Float32Array(analyser.frequencyBinCount))

  useEffect(() => {
    const cv = ref.current!
    const dpr = Math.min(2, window.devicePixelRatio || 1)
    cv.width = width * dpr
    cv.height = height * dpr
    const g = cv.getContext('2d')!
    g.scale(dpr, dpr)
    let raf = 0
    const sr = analyser.context.sampleRate
    const fMin = 30, fMax = 18000
    const xOf = (f: number) => (Math.log(f / fMin) / Math.log(fMax / fMin)) * width

    // approximate EQ magnitude (dB) at frequency f by summing band contributions
    const eqDb = (f: number) => {
      let db = 0
      for (const b of bandsRef.current) {
        if (b.type === 'highshelf') { if (f > b.freq) db += b.gainDb * Math.min(1, Math.log(f / b.freq) / Math.log(2.5)) }
        else if (b.type === 'lowshelf') { if (f < b.freq) db += b.gainDb }
        else {
          const oct = Math.log2(f / b.freq)
          const bw = 1 / Math.max(0.3, b.q)
          db += b.gainDb * Math.exp(-(oct * oct) / (2 * bw * bw))
        }
      }
      return db
    }

    const draw = () => {
      if (buf.current.length !== analyser.frequencyBinCount) buf.current = new Float32Array(analyser.frequencyBinCount)
      analyser.getFloatFrequencyData(buf.current)

      g.clearRect(0, 0, width, height)
      g.fillStyle = '#0e1015'
      g.fillRect(0, 0, width, height)

      // grid lines at 100/1k/10k
      g.strokeStyle = 'rgba(255,255,255,0.05)'
      g.lineWidth = 1
      for (const f of [100, 1000, 10000]) {
        const x = xOf(f)
        g.beginPath(); g.moveTo(x, 0); g.lineTo(x, height); g.stroke()
      }

      // spectrum filled area
      g.beginPath()
      g.moveTo(0, height)
      const n = buf.current.length
      for (let i = 1; i < n; i++) {
        const f = (i * sr) / (analyser.fftSize)
        if (f < fMin || f > fMax) continue
        const x = xOf(f)
        const db = buf.current[i]
        const t = Math.max(0, Math.min(1, (db + 90) / 90))
        const y = height - t * height
        g.lineTo(x, y)
      }
      g.lineTo(width, height)
      g.closePath()
      g.fillStyle = 'rgba(99,179,237,0.22)'
      g.fill()

      // EQ curve overlay (center = 0 dB, +/-12 dB range)
      const midY = height / 2
      const yOfDb = (db: number) => midY - (db / 12) * (height / 2)
      g.beginPath()
      let first = true
      for (let px = 0; px <= width; px += 2) {
        const f = fMin * Math.pow(fMax / fMin, px / width)
        const y = yOfDb(eqDb(f))
        if (first) { g.moveTo(px, y); first = false } else g.lineTo(px, y)
      }
      g.strokeStyle = '#22d3ee'
      g.lineWidth = 1.5
      g.stroke()
      // zero line
      g.strokeStyle = 'rgba(255,255,255,0.10)'
      g.lineWidth = 1
      g.beginPath(); g.moveTo(0, midY); g.lineTo(width, midY); g.stroke()

      raf = requestAnimationFrame(draw)
    }
    draw()
    return () => cancelAnimationFrame(raf)
  }, [analyser, width, height])

  return <canvas ref={ref} style={{ width, height }} className="rounded" />
}
