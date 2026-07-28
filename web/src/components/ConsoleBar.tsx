import { useEffect } from 'react'
import { useStore } from '../store'
import { useEngine } from '../state/engine-context'
import { PROFILES } from '../brain/targets'
import type { MonitorSource } from '../types'

export default function ConsoleBar() {
  const engine = useEngine()
  const dcaGroups = useStore((s) => s.dcaGroups)
  const muteGroups = useStore((s) => s.muteGroups)
  const monitorSource = useStore((s) => s.monitorSource)
  const matrix = useStore((s) => s.matrix)
  const recallScope = useStore((s) => s.recallScope)
  const oscillator = useStore((s) => s.oscillator)
  const recording = useStore((s) => s.recording)
  const recElapsed = useStore((s) => s.recElapsed)
  const recUrl = useStore((s) => s.recUrl)
  const undoDepth = useStore((s) => s.undoDepth)
  const redoDepth = useStore((s) => s.redoDepth)
  const channels = useStore((s) => s.channels)
  const mixMinusId = useStore((s) => s.mixMinusChannelId)

  const setDcaLevel = useStore((s) => s.setDcaLevel)
  const toggleMuteGroup = useStore((s) => s.toggleMuteGroup)
  const setMonitor = useStore((s) => s.setMonitor)
  const setRecallScope = useStore((s) => s.setRecallScope)
  const setOscillator = useStore((s) => s.setOscillator)
  const setRecording = useStore((s) => s.setRecording)
  const setRecElapsed = useStore((s) => s.setRecElapsed)
  const setMixMinus = useStore((s) => s.setMixMinusChannel)
  const undo = useStore((s) => s.undo)
  const redo = useStore((s) => s.redo)
  const clearSolo = useStore((s) => s.clearSolo)
  const commit = useStore((s) => s.commit)

  useEffect(() => {
    if (!recording) return
    const t0 = Date.now()
    const iv = setInterval(() => setRecElapsed(Math.floor((Date.now() - t0) / 1000)), 500)
    return () => clearInterval(iv)
  }, [recording, setRecElapsed])

  async function toggleRec() {
    if (recording) { const url = await engine.stopRecording(); setRecording(false, url) }
    else { engine.startRecording(); setRecording(true, null) }
  }

  const anySolo = channels.some((c) => c.soloed)
  const monBtn = (src: MonitorSource, label: string, on?: boolean) => (
    <button
      onClick={() => setMonitor(src)}
      aria-pressed={monitorSource === src}
      className={`rounded px-2 py-0.5 text-[10px] font-medium transition ${
        monitorSource === src ? 'bg-cyan-500 text-black' : on === false ? 'bg-[#15181f] text-zinc-600' : 'bg-[#1a1d25] text-zinc-300 hover:bg-[#222631]'
      }`}
    >{label}</button>
  )

  return (
    <section aria-label="Console shortcuts" className="flex max-w-full shrink-0 items-stretch gap-3 overflow-x-auto border-t border-[#1c1f27] bg-[#0c0d11] px-3 py-2">
      {/* DCA faders */}
      <Block title="DCA Groups">
        <div className="flex gap-3">
          {dcaGroups.map((d) => (
            <div key={d.id} className="flex w-14 flex-col items-center">
              <span className="text-[9px] text-zinc-400">{d.name}</span>
              <input type="range" min={-40} max={10} step={0.5} value={d.levelDb}
                onChange={(e) => setDcaLevel(d.id, parseFloat(e.target.value))}
                aria-label={`${d.name} DCA level`}
                className="h-1 w-full accent-violet-400" />
              <span className="tnum text-[9px] text-zinc-500">{d.levelDb >= 0 ? '+' : ''}{d.levelDb.toFixed(0)}</span>
            </div>
          ))}
        </div>
      </Block>

      {/* mute groups */}
      <Block title="Mute Groups">
        <div className="flex gap-1">
          {muteGroups.map((on, i) => (
            <button key={i} onClick={() => { commit(); toggleMuteGroup(i) }}
              aria-pressed={on}
              aria-label={`${on ? 'Release' : 'Engage'} mute group ${i + 1}`}
              className={`h-9 w-9 rounded text-[10px] font-bold transition ${on ? 'bg-red-600 text-white' : 'bg-[#1a1d25] text-zinc-400 hover:text-zinc-200'}`}>
              {i + 1}
            </button>
          ))}
        </div>
      </Block>

      {/* monitor / audition */}
      <Block title="Monitor (headphones — does not touch stream)">
        <div className="flex flex-wrap items-center gap-1">
          {monBtn('program', 'Program')}
          {monBtn('solo', anySolo ? 'Solo ●' : 'Solo', anySolo)}
          {monBtn('assist', 'Assist')}
          {monBtn('mixminus', 'Mix-Minus')}
          {anySolo && <button onClick={clearSolo} className="rounded bg-[#1a1d25] px-2 py-0.5 text-[10px] text-yellow-300 hover:bg-[#222631]">clear solo</button>}
        </div>
      </Block>

      {/* matrix outputs */}
      <Block title="Matrix Outputs">
        <div className="flex gap-2">
          {matrix.map((m) => (
            <button key={m.id} onClick={() => setMonitor(m.id)} title={m.blurb}
              aria-pressed={monitorSource === m.id}
              className={`flex w-20 flex-col rounded border px-1.5 py-1 text-left ${monitorSource === m.id ? 'border-cyan-500/60 bg-cyan-500/10' : 'border-[#1c1f27] bg-[#0e1015] hover:border-[#2a2e37]'}`}>
              <span className="text-[10px] font-medium text-zinc-200">{m.name}</span>
              <span className="tnum text-[9px] text-zinc-400">{m.momentaryLufs <= -90 ? '—' : m.momentaryLufs.toFixed(1)} <span className="text-zinc-600">/ {m.targetLufs}</span></span>
            </button>
          ))}
        </div>
        <div className="mt-1 flex items-center gap-1">
          <span className="text-[9px] text-zinc-600">N-1 guest:</span>
          <select value={mixMinusId ?? 0} onChange={(e) => { const v = +e.target.value; setMixMinus(v === 0 ? null : v) }}
            aria-label="Mix-minus guest channel"
            className="rounded border border-[#232733] bg-[#0c0d11] px-1 py-0.5 text-[10px] text-zinc-300">
            <option value={0}>none</option>
            {channels.map((c) => <option key={c.id} value={c.id}>{PROFILES[c.cls].label} ({c.name})</option>)}
          </select>
        </div>
      </Block>

      {/* recording */}
      <Block title="Record">
        <div className="flex flex-col gap-1">
          <button onClick={toggleRec}
            aria-pressed={recording}
            className={`rounded px-2 py-1 text-[10px] font-semibold ${recording ? 'bg-red-600 text-white' : 'bg-[#1a1d25] text-red-300 hover:bg-[#222631]'}`}>
            {recording ? `● REC ${fmtTime(recElapsed)}` : 'Record program'}
          </button>
          {recUrl && !recording && <a href={recUrl} download="automix-program.webm" className="text-center text-[9px] text-cyan-400 hover:underline">download last</a>}
        </div>
      </Block>

      {/* oscillator */}
      <Block title="Osc / Cal">
        <div className="flex flex-col gap-1">
          <button onClick={() => setOscillator({ on: !oscillator.on })}
            aria-pressed={oscillator.on}
            className={`rounded px-2 py-0.5 text-[10px] font-medium ${oscillator.on ? 'bg-amber-500 text-black' : 'bg-[#1a1d25] text-zinc-300 hover:bg-[#222631]'}`}>
            {oscillator.on ? 'TONE ON' : 'osc off'}
          </button>
          <div className="flex gap-1">
            {(['tone', 'pink'] as const).map((t) => (
              <button key={t} onClick={() => setOscillator({ type: t })}
                aria-pressed={oscillator.type === t}
                className={`flex-1 rounded px-1 py-0.5 text-[9px] ${oscillator.type === t ? 'bg-[#2a2e37] text-zinc-100' : 'bg-[#1a1d25] text-zinc-500'}`}>{t}</button>
            ))}
          </div>
        </div>
      </Block>

      {/* recall scope */}
      <Block title="AI Scope">
        <div className="grid grid-cols-2 gap-x-2 gap-y-0.5">
          {(['levels', 'eq', 'dynamics', 'routing'] as const).map((k) => (
            <label key={k} className="flex cursor-pointer items-center gap-1 text-[10px] text-zinc-400">
              <input type="checkbox" checked={recallScope[k]} onChange={(e) => setRecallScope({ [k]: e.target.checked })} className="accent-cyan-400" />
              {k}
            </label>
          ))}
        </div>
      </Block>

      {/* undo */}
      <Block title="History">
        <div className="flex gap-1">
          <button onClick={undo} disabled={undoDepth === 0} className="rounded bg-[#1a1d25] px-2 py-1 text-[10px] text-zinc-300 hover:bg-[#222631] disabled:opacity-30">↶ Undo</button>
          <button onClick={redo} disabled={redoDepth === 0} className="rounded bg-[#1a1d25] px-2 py-1 text-[10px] text-zinc-300 hover:bg-[#222631] disabled:opacity-30">Redo ↷</button>
        </div>
      </Block>
    </section>
  )
}

function Block({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="flex shrink-0 flex-col gap-1 border-r border-[#1c1f27] pr-3 last:border-r-0">
      <span className="text-[9px] uppercase tracking-wider text-zinc-600">{title}</span>
      {children}
    </div>
  )
}
function fmtTime(s: number) {
  const m = Math.floor(s / 60)
  return `${m}:${String(s % 60).padStart(2, '0')}`
}
