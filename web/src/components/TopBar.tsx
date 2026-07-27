import { useStore } from '../store'
import { SCENES } from '../scenes/scenes'

export default function TopBar({ onStop }: { onStop: () => void }) {
  const frozen = useStore((s) => s.frozen)
  const bypassed = useStore((s) => s.bypassed)
  const mixMode = useStore((s) => s.mixMode)
  const status = useStore((s) => s.brainStatus)
  const mode = useStore((s) => s.mode)
  const sceneId = useStore((s) => s.sceneId)
  const integ = useStore((s) => s.master.integratedLufs)
  const short = useStore((s) => s.master.shortLufs)
  const tp = useStore((s) => s.master.truePeakDb)

  const toggleFreeze = useStore((s) => s.toggleFreeze)
  const toggleBypass = useStore((s) => s.toggleBypass)
  const setMixMode = useStore((s) => s.setMixMode)
  const togglePatch = useStore((s) => s.togglePatch)
  const showPatch = useStore((s) => s.showPatch)
  const toggleDevices = useStore((s) => s.toggleDevices)
  const showDevices = useStore((s) => s.showDevices)

  const statusColor = status === 'ok' ? 'text-emerald-400' : status === 'stalled' ? 'text-amber-400' : 'text-red-400'

  return (
    <div className="flex items-center gap-3 border-b border-[#1c1f27] bg-[#0c0d11] px-4 py-2.5">
      <div className="flex items-center gap-2">
        <span className="rec-dot inline-block h-2.5 w-2.5 rounded-full bg-red-500" />
        <span className="text-sm font-semibold tracking-tight text-white">AutoMix</span>
        <span className="text-[10px] uppercase tracking-widest text-zinc-500">Broadcast</span>
      </div>

      <div className="ml-2 rounded-md bg-[#15181f] px-2 py-1 text-[11px] text-zinc-400">
        {mode === 'mic' ? 'Live Mic' : 'Synthetic Stage'} · {SCENES[sceneId].name}
      </div>

      <div className="ml-auto flex items-center gap-3 tnum text-[11px] text-zinc-400">
        <Readout label="SHORT" value={`${fmtLufs(short)}`} unit="LUFS" />
        <Readout label="INTEG" value={`${fmtLufs(integ)}`} unit="LUFS" />
        <Readout label="TP" value={`${tp <= -90 ? '—' : tp.toFixed(1)}`} unit="dBTP" warn={tp > -1} />
      </div>

      <div className="flex items-center gap-1.5">
        <div className={`mr-1 flex items-center gap-1 text-[11px] ${statusColor}`}>
          <span className="inline-block h-1.5 w-1.5 rounded-full bg-current" />
          {status === 'ok' ? 'Brain OK' : status === 'stalled' ? 'Stalled' : 'Error'}
        </div>

        <button
          onClick={() => toggleDevices()}
          className={`rounded-md px-3 py-1.5 text-xs font-semibold transition ${showDevices ? 'bg-cyan-500 text-black' : 'bg-[#15181f] text-zinc-300 hover:bg-[#1b1f28]'}`}
          title="Choose the physical mic input and program output device"
        >
          Devices
        </button>

        <button
          onClick={() => togglePatch()}
          className={`rounded-md px-3 py-1.5 text-xs font-semibold transition ${showPatch ? 'bg-cyan-500 text-black' : 'bg-[#15181f] text-cyan-300 hover:bg-[#1b1f28]'}`}
          title="Assign which physical input feeds each channel"
        >
          Patch
        </button>

        <ModeToggle mixMode={mixMode} setMixMode={setMixMode} />

        <button
          onClick={toggleFreeze}
          className={`rounded-md px-3 py-1.5 text-xs font-semibold transition ${
            frozen ? 'bg-amber-500 text-black' : 'bg-[#15181f] text-amber-300 hover:bg-[#1b1f28]'
          }`}
          title="Lock all AI parameters at their current values"
        >
          {frozen ? 'FROZEN' : 'FREEZE'}
        </button>

        <button
          onClick={toggleBypass}
          className={`rounded-md px-3 py-1.5 text-xs font-semibold transition ${
            bypassed ? 'bg-red-600 text-white' : 'bg-[#15181f] text-red-300 hover:bg-[#1b1f28]'
          }`}
          title="Hard bypass to a safe static sum of raw channels"
        >
          {bypassed ? 'SAFE MIX' : 'BYPASS'}
        </button>

        <button
          onClick={onStop}
          className="ml-1 rounded-md bg-[#15181f] px-2.5 py-1.5 text-xs text-zinc-400 hover:bg-[#1b1f28]"
        >
          Stop
        </button>
      </div>
    </div>
  )
}

function ModeToggle({ mixMode, setMixMode }: { mixMode: 'soundcheck' | 'live'; setMixMode: (m: 'soundcheck' | 'live') => void }) {
  return (
    <div className="flex overflow-hidden rounded-md border border-[#232733] text-[11px]">
      {(['soundcheck', 'live'] as const).map((m) => (
        <button
          key={m}
          onClick={() => setMixMode(m)}
          className={`px-2.5 py-1.5 font-medium transition ${
            mixMode === m ? (m === 'live' ? 'bg-red-600/80 text-white' : 'bg-cyan-600/80 text-white') : 'bg-[#15181f] text-zinc-400 hover:bg-[#1b1f28]'
          }`}
          title={m === 'live' ? 'Conservative: rate-limited, smaller moves' : 'Aggressive: full-range moves for setup'}
        >
          {m === 'live' ? 'LIVE' : 'SOUNDCHECK'}
        </button>
      ))}
    </div>
  )
}

function Readout({ label, value, unit, warn }: { label: string; value: string; unit: string; warn?: boolean }) {
  return (
    <div className="flex flex-col items-end leading-none">
      <span className="text-[9px] uppercase tracking-wider text-zinc-600">{label}</span>
      <span className={warn ? 'text-red-400' : 'text-zinc-200'}>
        {value} <span className="text-[9px] text-zinc-600">{unit}</span>
      </span>
    </div>
  )
}

function fmtLufs(v: number) {
  return v <= -90 || !isFinite(v) ? '—' : v.toFixed(1)
}
