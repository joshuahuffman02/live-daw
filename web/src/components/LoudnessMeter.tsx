import { useEffect, useRef } from 'react'
import { useEngine } from '../state/engine-context'

// EBU R128 style loudness meter. Reads the loudness worklet's telemetry off the
// engine each frame (smooth), draws momentary + short-term + integrated against the
// scene's target, plus a true-peak column with the ceiling line.
export default function LoudnessMeter({ target }: { target: number }) {
  const engine = useEngine()
  const ref = useRef<HTMLCanvasElement>(null)
  const W = 300, H = 150

  useEffect(() => {
    const cv = ref.current!
    const dpr = Math.min(2, window.devicePixelRatio || 1)
    cv.width = W * dpr
    cv.height = H * dpr
    const g = cv.getContext('2d')!
    g.scale(dpr, dpr)
    let raf = 0
    const top = -2, bot = -36
    const yOf = (l: number) => {
      const t = (Math.max(bot, Math.min(top, l)) - bot) / (top - bot)
      return H - t * H
    }
    const meterW = W - 70

    const draw = () => {
      const t = engine.loudnessTel
      g.clearRect(0, 0, W, H)
      g.fillStyle = '#0e1015'
      g.fillRect(0, 0, W, H)

      // scale ticks
      g.font = '9px ui-sans-serif'
      g.textBaseline = 'middle'
      for (const l of [-6, -14, -18, -23, -30]) {
        const y = yOf(l)
        g.strokeStyle = 'rgba(255,255,255,0.06)'
        g.beginPath(); g.moveTo(0, y); g.lineTo(meterW, y); g.stroke()
        g.fillStyle = '#52525b'
        g.fillText(`${l}`, meterW + 4, y)
      }

      // momentary bar
      const mY = yOf(t.momentary)
      const grad = g.createLinearGradient(0, H, 0, 0)
      grad.addColorStop(0, '#0ea5e9')
      grad.addColorStop(0.7, '#22d3ee')
      grad.addColorStop(0.92, '#fbbf24')
      grad.addColorStop(1, '#ef4444')
      g.fillStyle = grad
      g.fillRect(0, mY, meterW * 0.62, H - mY)

      // short-term bar
      const sY = yOf(t.short)
      g.fillStyle = 'rgba(167,139,250,0.65)'
      g.fillRect(meterW * 0.66, sY, meterW * 0.34, H - sY)

      // integrated marker
      const iY = yOf(t.integrated)
      g.strokeStyle = '#e7e9ee'
      g.lineWidth = 1.5
      g.beginPath(); g.moveTo(0, iY); g.lineTo(meterW, iY); g.stroke()

      // target line
      const tY = yOf(target)
      g.strokeStyle = '#f59e0b'
      g.setLineDash([4, 3])
      g.beginPath(); g.moveTo(0, tY); g.lineTo(meterW, tY); g.stroke()
      g.setLineDash([])

      // labels
      g.fillStyle = '#a5b4fc'; g.font = '8px ui-sans-serif'
      g.fillText('S', meterW * 0.66 + 2, 8)
      g.fillStyle = '#22d3ee'
      g.fillText('M', 2, 8)

      // true-peak column on the right
      const tpX = W - 18
      const tpTop = 0, tpBot = -18
      const tpY = (d: number) => H - ((Math.max(tpBot, Math.min(tpTop, d)) - tpBot) / (tpTop - tpBot)) * H
      g.fillStyle = '#15181f'
      g.fillRect(tpX, 0, 14, H)
      const pY = tpY(t.truePeak)
      g.fillStyle = t.truePeak > -1 ? '#ef4444' : '#10b981'
      g.fillRect(tpX, pY, 14, H - pY)
      // ceiling line at -1 dBTP
      g.strokeStyle = '#ef4444'; g.lineWidth = 1
      g.beginPath(); g.moveTo(tpX, tpY(-1)); g.lineTo(tpX + 14, tpY(-1)); g.stroke()
      g.fillStyle = '#52525b'; g.font = '8px ui-sans-serif'
      g.fillText('TP', tpX, H - 6)

      raf = requestAnimationFrame(draw)
    }
    draw()
    return () => cancelAnimationFrame(raf)
  }, [engine, target])

  return <canvas ref={ref} style={{ width: W, height: H }} className="rounded" />
}
