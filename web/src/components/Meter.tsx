import { useEffect, useRef } from 'react'

// Vertical level meter that self-animates from an AnalyserNode (reads the live
// audio thread directly via RAF — not through React state).
export default function Meter({
  analyser, width = 10, height = 90, accent = '#22d3ee',
}: {
  analyser: AnalyserNode
  width?: number
  height?: number
  accent?: string
}) {
  const ref = useRef<HTMLCanvasElement>(null)
  const peakHold = useRef(-100)
  const buf = useRef(new Float32Array(analyser.fftSize))

  useEffect(() => {
    const cv = ref.current!
    const dpr = Math.min(2, window.devicePixelRatio || 1)
    cv.width = width * dpr
    cv.height = height * dpr
    const g = cv.getContext('2d')!
    g.scale(dpr, dpr)
    let raf = 0

    const dbToY = (db: number) => {
      const t = Math.max(0, Math.min(1, (db + 60) / 60))
      return height - t * height
    }

    const draw = () => {
      if (buf.current.length !== analyser.fftSize) buf.current = new Float32Array(analyser.fftSize)
      analyser.getFloatTimeDomainData(buf.current)
      let sum = 0, peak = 0
      for (let i = 0; i < buf.current.length; i++) {
        const v = buf.current[i]
        sum += v * v
        const a = Math.abs(v)
        if (a > peak) peak = a
      }
      const rms = Math.sqrt(sum / buf.current.length)
      const rmsDb = rms > 1e-6 ? 20 * Math.log10(rms) : -100
      const peakDb = peak > 1e-6 ? 20 * Math.log10(peak) : -100
      peakHold.current = Math.max(peakDb, peakHold.current - 0.6)

      g.clearRect(0, 0, width, height)
      // track
      g.fillStyle = '#15181f'
      g.fillRect(0, 0, width, height)
      // level
      const y = dbToY(rmsDb)
      const grad = g.createLinearGradient(0, height, 0, 0)
      grad.addColorStop(0, accent)
      grad.addColorStop(0.7, accent)
      grad.addColorStop(0.85, '#fbbf24')
      grad.addColorStop(1, '#ef4444')
      g.fillStyle = grad
      g.fillRect(0, y, width, height - y)
      // peak hold tick
      const py = dbToY(peakHold.current)
      g.fillStyle = peakHold.current > -1 ? '#ef4444' : '#e7e9ee'
      g.fillRect(0, py - 1, width, 1.5)
      // -18 reference
      g.fillStyle = 'rgba(255,255,255,0.12)'
      g.fillRect(0, dbToY(-18), width, 1)

      raf = requestAnimationFrame(draw)
    }
    draw()
    return () => cancelAnimationFrame(raf)
  }, [analyser, width, height, accent])

  return <canvas ref={ref} style={{ width, height }} className="rounded-sm" />
}
