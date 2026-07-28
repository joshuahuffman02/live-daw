import { useStore } from '../store'
import { SCENES } from '../scenes/scenes'
import { useEngine } from '../state/engine-context'
import LoudnessMeter from './LoudnessMeter'
import SpectrumEq from './SpectrumEq'

export default function MasterPanel() {
  const engine = useEngine()
  const m = useStore((s) => s.master)
  const sceneId = useStore((s) => s.sceneId)
  const bypassed = useStore((s) => s.bypassed)
  const scene = SCENES[sceneId]

  return (
    <div className="rounded-lg border border-[#1c1f27] bg-[#101218] p-3">
      <div className="mb-2 flex items-center justify-between">
        <span className="text-xs font-semibold uppercase tracking-wider text-zinc-300">Broadcast Master</span>
        <div className="flex items-center gap-1.5">
          {m.clip && <span className="rounded bg-red-600 px-1.5 py-0.5 text-[9px] font-semibold text-white">CLIP</span>}
          {bypassed && <span className="rounded bg-red-600 px-1.5 py-0.5 text-[9px] font-semibold text-white">SAFE BYPASS</span>}
        </div>
      </div>

      <div className="md:grid md:grid-cols-[minmax(280px,0.9fr)_minmax(280px,1.1fr)] md:gap-5 lg:block">
        <div>
          {/* chain */}
          <div className="mb-3 flex items-center gap-1 text-[9px] text-zinc-500">
            <Chip>Glue {m.glueGrDb.toFixed(1)}</Chip>
            <Arrow />
            <Chip>Master EQ</Chip>
            <Arrow />
            <Chip warn={m.limiterGrDb < -0.3}>Limiter {m.limiterGrDb.toFixed(1)}</Chip>
          </div>

          <LoudnessMeter target={scene.masterTargetLufs} />
        </div>

        <div className="min-w-0">
          <div className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1.5 tnum text-[11px] md:mt-0 lg:mt-3">
            <Row label="Integrated" value={fmt(m.integratedLufs)} unit="LUFS" big />
            <Row label="Target" value={scene.masterTargetLufs.toFixed(0)} unit="LUFS" accent="text-amber-400" />
            <Row label="Short-term" value={fmt(m.shortLufs)} unit="LUFS" />
            <Row label="Momentary" value={fmt(m.momentaryLufs)} unit="LUFS" />
            <Row label="True Peak" value={fmt(m.truePeakDb)} unit="dBTP" accent={m.truePeakDb > -1 ? 'text-red-400' : 'text-emerald-400'} />
            <Row label="Limiter GR" value={m.limiterGrDb.toFixed(1)} unit="dB" accent={m.limiterGrDb < -0.3 ? 'text-cyan-400' : 'text-zinc-400'} />
          </div>

          {/* phase correlation — mono compatibility for phone listeners */}
          <div className="mt-3">
            <div className="mb-1 flex items-center justify-between text-[9px] uppercase tracking-wider text-zinc-500">
              <span>Phase correlation</span>
              <span className={`tnum ${m.correlation < 0 ? 'text-red-400' : m.correlation < 0.4 ? 'text-amber-400' : 'text-emerald-400'}`}>{m.correlation.toFixed(2)}</span>
            </div>
            <Correlation value={m.correlation} />
          </div>

          {/* master RTA */}
          <div className="mt-3">
            <div className="mb-1 text-[9px] uppercase tracking-wider text-zinc-500">Master RTA</div>
            <SpectrumEq analyser={engine.recAnalyser} bands={[]} width={300} height={48} />
          </div>
        </div>
      </div>
    </div>
  )
}

function Correlation({ value }: { value: number }) {
  // map -1..+1 to 0..100% ; marker position
  const pct = ((value + 1) / 2) * 100
  return (
    <div className="relative h-3 w-full overflow-hidden rounded bg-gradient-to-r from-red-600/70 via-amber-500/40 to-emerald-600/60">
      <div className="absolute top-0 h-3 w-0.5 bg-white" style={{ left: `calc(${pct}% - 1px)` }} />
      <div className="absolute left-1/2 top-0 h-3 w-px bg-white/20" />
    </div>
  )
}

function Row({ label, value, unit, accent = 'text-zinc-200', big }: { label: string; value: string; unit: string; accent?: string; big?: boolean }) {
  return (
    <div className="flex items-baseline justify-between">
      <span className="text-zinc-500">{label}</span>
      <span className={`${accent} ${big ? 'text-sm font-semibold' : ''}`}>
        {value}<span className="ml-0.5 text-[9px] text-zinc-500">{unit}</span>
      </span>
    </div>
  )
}

function Chip({ children, warn }: { children: React.ReactNode; warn?: boolean }) {
  return <span className={`rounded px-1.5 py-0.5 ${warn ? 'bg-cyan-500/20 text-cyan-300' : 'bg-[#1a1d25] text-zinc-400'}`}>{children}</span>
}
function Arrow() { return <span className="text-zinc-700">→</span> }

const fmt = (v: number) => (v <= -90 || !isFinite(v) ? '—' : v.toFixed(1))
