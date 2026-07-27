import { useStore } from '../store'
import type { LogEntry } from '../store'

const KIND_COLOR: Record<LogEntry['kind'], string> = {
  scene: 'text-cyan-400',
  label: 'text-violet-400',
  override: 'text-amber-400',
  safety: 'text-red-400',
  eq: 'text-emerald-400',
  info: 'text-zinc-500',
}

export default function BrainLog() {
  const log = useStore((s) => s.log)

  return (
    <div className="flex min-h-0 flex-1 flex-col rounded-lg border border-[#1c1f27] bg-[#101218] p-3">
      <div className="mb-2 flex items-center justify-between">
        <span className="text-xs font-semibold uppercase tracking-wider text-zinc-300">Decision Log</span>
        <span className="text-[9px] uppercase tracking-wider text-zinc-600">what & why</span>
      </div>
      <div className="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto pr-1">
        {log.length === 0 && <div className="text-[11px] text-zinc-600">Awaiting decisions…</div>}
        {log.map((e) => (
          <div key={e.id} className="flex gap-2 text-[10px] leading-tight">
            <span className="tnum shrink-0 text-zinc-700">{time(e.t)}</span>
            <span className={`shrink-0 uppercase ${KIND_COLOR[e.kind]}`}>{e.kind}</span>
            <span className="text-zinc-400">{e.text}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

function time(t: number) {
  const d = new Date(t)
  return `${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`
}
