import { useEngine } from '../state/engine-context'
import { useStore } from '../store'
import { PROFILES } from '../brain/targets'
import { dbToGain } from '../audio/util'
import type { ParamKey, SourceClass } from '../types'
import Meter from './Meter'
import SpectrumEq from './SpectrumEq'

const SELECTABLE: SourceClass[] = [
  'speech', 'leadVocal', 'bgv', 'acousticGuitar', 'electricGuitar', 'bass', 'kick', 'keys',
]

export default function ChannelStrip({ id }: { id: number }) {
  const engine = useEngine()
  const nodes = engine.channels.find((c) => c.id === id)!
  const ch = useStore((s) => s.channels.find((c) => c.id === id))
  const setLabel = useStore((s) => s.setLabel)
  const setOverride = useStore((s) => s.setOverride)
  const patchChannel = useStore((s) => s.patchChannel)
  const pushLog = useStore((s) => s.pushLog)
  const select = useStore((s) => s.select)
  const selected = useStore((s) => s.selectedChannel === id)
  const toggleMute = useStore((s) => s.toggleMute)
  const toggleSolo = useStore((s) => s.toggleSolo)
  const commit = useStore((s) => s.commit)
  const inputId = useStore((s) => s.patch[id])
  const inputs = useStore((s) => s.inputs)
  if (!ch) return null

  const inputName = inputId == null ? null : inputs.find((i) => i.id === inputId)?.name ?? null

  const profile = PROFILES[ch.cls]
  const conf = Math.round(ch.confidence * 100)
  const confColor = ch.confidence > 0.7 ? 'text-emerald-400' : ch.confidence > 0.45 ? 'text-amber-400' : 'text-zinc-500'
  const anyOverride = Object.values(ch.overrides).some(Boolean) || ch.labelLocked

  function toggleOverride(key: ParamKey) {
    const on = !ch!.overrides[key]
    commit()
    setOverride(id, key, on)
    pushLog('override', `${ch!.name}: ${key.toUpperCase()} → ${on ? 'MANUAL' : 'AUTO'}`)
  }

  function onFader(db: number) {
    if (!ch!.overrides.fader) { commit(); setOverride(id, 'fader', true) }
    nodes.fader.gain.setTargetAtTime(dbToGain(db), engine.ctx.currentTime, 0.05)
    patchChannel(id, { faderDb: db })
  }

  function toggleLock() {
    commit()
    setLabel(id, ch!.cls, !ch!.labelLocked)
    pushLog('label', `${ch!.name}: label ${!ch!.labelLocked ? 'LOCKED' : 'unlocked'} (${PROFILES[ch!.cls].label})`)
  }

  function onRelabel(cls: SourceClass) {
    commit()
    setLabel(id, cls, true)
    pushLog('label', `${ch!.name}: operator set label → ${PROFILES[cls].label} (locked)`)
  }

  return (
    <div
      onClick={() => select(id)}
      role="group"
      aria-label={`Channel ${id}: ${ch.name}, detected as ${profile.label}`}
      className={`flex w-[176px] shrink-0 flex-col gap-2 rounded-lg border bg-[#101218] p-2.5 ${
        selected ? 'border-cyan-500/60' : anyOverride ? 'border-amber-500/30' : 'border-[#1c1f27]'
      }`}
    >
      {/* header */}
      <div className="flex items-start justify-between">
        <button
          type="button"
          onClick={(e) => { e.stopPropagation(); select(id) }}
          className="min-w-0 text-left"
          aria-label={`Edit channel ${id}, ${ch.name}`}
        >
          <div className="flex items-center gap-1">
            <span className="truncate text-sm font-semibold text-white">{profile.label}</span>
            {ch.labelLocked && <span className="rounded bg-amber-500/15 px-1 text-[8px] uppercase tracking-wide text-amber-300">locked</span>}
            {ch.isStereo && <span title="stereo" className="text-[8px] text-zinc-500">ST</span>}
            {ch.clip && <span title="clip" className="ml-auto inline-block h-2 w-2 rounded-full bg-red-500" />}
          </div>
          <div className="flex items-center gap-1.5 text-[10px]">
            <span className="rounded bg-[#1a1d25] px-1 text-zinc-500">{ch.bus}</span>
            {inputName
              ? <span className="truncate text-zinc-600" title={`input: ${inputName}`}>← {inputName}</span>
              : <span className="text-red-400">no input</span>}
          </div>
        </button>
        <div className="flex flex-col items-end">
          <span className={`tnum text-xs font-medium ${confColor}`}>{conf}%</span>
          <button
            type="button"
            onClick={(e) => { e.stopPropagation(); toggleLock() }}
            aria-pressed={ch.labelLocked}
            aria-label={`${ch.labelLocked ? 'Unlock' : 'Lock'} detected role for channel ${id}`}
            className="min-h-6 rounded px-1 text-[9px] text-zinc-500 hover:bg-[#1a1d25] hover:text-zinc-300"
          >
            {ch.labelLocked ? 'unlock' : 'lock'}
          </button>
        </div>
      </div>

      {/* relabel */}
      <select
        value={ch.cls}
        onClick={(e) => e.stopPropagation()}
        onChange={(e) => onRelabel(e.target.value as SourceClass)}
        aria-label={`Role for channel ${id}, ${ch.name}`}
        className="w-full rounded border border-[#232733] bg-[#0c0d11] px-1 py-0.5 text-[10px] text-zinc-400"
      >
        {SELECTABLE.map((c) => (
          <option key={c} value={c}>{PROFILES[c].label}{ch.cls === c && !ch.labelLocked ? ' · detected' : ''}</option>
        ))}
      </select>

      {/* mute / solo */}
      <div className="flex items-center gap-1">
        <button
          onClick={(e) => { e.stopPropagation(); commit(); toggleMute(id) }}
          aria-pressed={ch.muted}
          aria-label={`${ch.muted ? 'Unmute' : 'Mute'} channel ${id}, ${ch.name}`}
          className={`min-h-7 flex-1 rounded px-1 py-1 text-[10px] font-bold transition ${ch.muted ? 'bg-red-600 text-white' : 'bg-[#1a1d25] text-zinc-400 hover:text-zinc-200'}`}
        >M</button>
        <button
          onClick={(e) => { e.stopPropagation(); toggleSolo(id) }}
          aria-pressed={ch.soloed}
          aria-label={`${ch.soloed ? 'Unsolo' : 'Solo'} channel ${id}, ${ch.name}`}
          className={`min-h-7 flex-1 rounded px-1 py-1 text-[10px] font-bold transition ${ch.soloed ? 'bg-yellow-400 text-black' : 'bg-[#1a1d25] text-zinc-400 hover:text-zinc-200'}`}
        >S</button>
        {ch.dca > 0 && <span className="rounded bg-[#1a1d25] px-1 py-1 text-[9px] text-violet-300" title="DCA group">D{ch.dca}</span>}
        {ch.sceneSafe && <span className="rounded bg-emerald-500/20 px-1 py-1 text-[9px] text-emerald-300" title="safe from scene recall">SAFE</span>}
      </div>

      {/* meters */}
      <div className="flex items-end gap-2">
        <div className="flex flex-col items-center gap-0.5">
          <Meter analyser={nodes.preAnalyser} accent="#64748b" />
          <span className="text-[8px] uppercase tracking-wider text-zinc-600">in</span>
          <span className="tnum text-[9px] text-zinc-500">{fmtDb(ch.preRmsDb)}</span>
        </div>
        <div className="flex flex-col items-center gap-0.5">
          <Meter analyser={nodes.postAnalyser} accent="#34d399" />
          <span className="text-[8px] uppercase tracking-wider text-zinc-600">out</span>
          <span className="tnum text-[9px] text-zinc-400">{fmtDb(ch.postRmsDb)}</span>
        </div>
        <div className="flex flex-1 flex-col gap-1 text-[9px] text-zinc-500">
          <Stat label="TRIM" value={`${fmtSigned(ch.trimDb)}`} />
          <Stat label="HPF" value={`${Math.round(ch.hpfHz)}`} />
          <Stat label="GATE" value={ch.gateOpen ? 'open' : '—'} color={ch.gateOpen ? 'text-emerald-400' : 'text-zinc-600'} />
          <Stat label="COMP" value={`${ch.compGrDb.toFixed(1)}`} color={ch.compGrDb < -0.5 ? 'text-cyan-400' : 'text-zinc-600'} />
          {ch.isSpeech && <Stat label="AMIX" value={`${fmtSigned(ch.automixGainDb)}`} color="text-violet-400" />}
        </div>
      </div>

      {/* spectrum + EQ */}
      <SpectrumEq analyser={nodes.postAnalyser} bands={ch.eqBands} />

      {/* fader */}
      <div className="flex items-center gap-2">
        <input
          type="range"
          min={-40}
          max={6}
          step={0.5}
          value={clampN(ch.faderDb, -40, 6)}
          onClick={(e) => e.stopPropagation()}
          onChange={(e) => onFader(parseFloat(e.target.value))}
          aria-label={`Fader for channel ${id}, ${ch.name}`}
          className="h-1 flex-1 accent-cyan-400"
        />
        <span className="tnum w-10 text-right text-[10px] text-zinc-300">{fmtSigned(ch.faderDb)}</span>
      </div>

      {/* override chips */}
      <div className="flex items-center gap-1">
        {(['eq', 'comp', 'fader'] as ParamKey[]).map((k) => (
          <button
            key={k}
            onClick={(e) => { e.stopPropagation(); toggleOverride(k) }}
            aria-pressed={ch.overrides[k]}
            aria-label={`${k === 'eq' ? 'Equalizer' : k === 'comp' ? 'Dynamics' : 'Level'} ${ch.overrides[k] ? 'manual override' : 'automatic'} for channel ${id}, ${ch.name}`}
            className={`min-h-6 flex-1 rounded px-1 py-0.5 text-[9px] font-medium uppercase tracking-wide transition ${
              ch.overrides[k] ? 'bg-amber-500/80 text-black' : 'bg-[#1a1d25] text-zinc-500 hover:text-zinc-300'
            }`}
            title={ch.overrides[k] ? 'manual — AI off' : 'auto — click to take manual'}
          >
            {k === 'eq' ? 'EQ' : k === 'comp' ? 'Dyn' : 'Lvl'}
          </button>
        ))}
      </div>

      {/* reason */}
      <div className="h-9 overflow-hidden text-[9px] leading-tight text-cyan-300/80">{ch.reason}</div>
    </div>
  )
}

function Stat({ label, value, color = 'text-zinc-400' }: { label: string; value: string; color?: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-zinc-600">{label}</span>
      <span className={`tnum ${color}`}>{value}</span>
    </div>
  )
}

const fmtDb = (v: number) => (v <= -90 || !isFinite(v) ? '−∞' : v.toFixed(0))
const fmtSigned = (v: number) => (v <= -59 ? '−∞' : (v >= 0 ? '+' : '') + v.toFixed(1))
const clampN = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, isFinite(v) ? v : lo))
