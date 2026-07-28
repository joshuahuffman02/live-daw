import { useState } from 'react'
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
  const [view, setView] = useState<'operator' | 'all'>('operator')
  const log = useStore((s) => s.log)
  const visible = view === 'operator'
    ? log.filter((entry) =>
        entry.kind !== 'eq' &&
        !(entry.kind === 'label' && (
          entry.text.startsWith('Re-labeled ') ||
          entry.text.includes('input changed — re-identifying')
        )),
      )
    : log

  return (
    <div className="flex min-h-0 flex-1 flex-col rounded-lg border border-[#1c1f27] bg-[#101218] p-3">
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-zinc-300">Activity</div>
          <div className="text-[9px] text-zinc-600">
            {visible.length} {view === 'operator' ? 'operator events' : 'detailed decisions'}
          </div>
        </div>
        <div className="flex rounded-md border border-[#232733] p-0.5" role="group" aria-label="Activity detail">
          <button
            type="button"
            onClick={() => setView('operator')}
            aria-pressed={view === 'operator'}
            className={`rounded px-2 py-1 text-[9px] font-medium ${
              view === 'operator' ? 'bg-cyan-600/80 text-white' : 'text-zinc-500 hover:text-zinc-300'
            }`}
          >
            Operator
          </button>
          <button
            type="button"
            onClick={() => setView('all')}
            aria-pressed={view === 'all'}
            className={`rounded px-2 py-1 text-[9px] font-medium ${
              view === 'all' ? 'bg-cyan-600/80 text-white' : 'text-zinc-500 hover:text-zinc-300'
            }`}
          >
            All decisions
          </button>
        </div>
      </div>
      <div className="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto pr-1">
        {visible.length === 0 && <div className="text-[11px] text-zinc-600">No operator events yet. Open All decisions for detailed automation.</div>}
        {visible.map((e) => (
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
