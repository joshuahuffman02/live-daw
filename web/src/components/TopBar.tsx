import { useEffect, useState } from 'react'
import { useStore } from '../store'
import { SCENES } from '../scenes/scenes'

export default function TopBar({ onStop }: { onStop: () => void }) {
  const [safeReleaseArmed, setSafeReleaseArmed] = useState(false)
  const [stopArmed, setStopArmed] = useState(false)
  const frozen = useStore((s) => s.frozen)
  const bypassed = useStore((s) => s.bypassed)
  const mixMode = useStore((s) => s.mixMode)
  const status = useStore((s) => s.brainStatus)
  const mode = useStore((s) => s.mode)
  const sceneId = useStore((s) => s.sceneId)
  const sceneTransition = useStore((s) => s.sceneTransition)
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
  const toggleRecordingSessions = useStore((s) => s.toggleRecordingSessions)
  const recording = useStore((s) => s.recording)

  const statusColor = status === 'ok' ? 'text-emerald-400' : status === 'stalled' ? 'text-amber-400' : 'text-red-400'
  const transitionHold = sceneTransition
    ? bypassed && frozen
      ? 'SAFE + FREEZE'
      : bypassed
        ? 'SAFE'
        : frozen
          ? 'FREEZE'
          : null
    : null

  useEffect(() => {
    if (!safeReleaseArmed) return
    const timer = window.setTimeout(() => setSafeReleaseArmed(false), 4000)
    return () => window.clearTimeout(timer)
  }, [safeReleaseArmed])

  useEffect(() => {
    if (!stopArmed) return
    const timer = window.setTimeout(() => setStopArmed(false), 4000)
    return () => window.clearTimeout(timer)
  }, [stopArmed])

  useEffect(() => {
    if (!bypassed) setSafeReleaseArmed(false)
  }, [bypassed])

  const handleSafe = () => {
    if (!bypassed) {
      toggleBypass()
      return
    }
    if (!safeReleaseArmed) {
      setSafeReleaseArmed(true)
      return
    }
    setSafeReleaseArmed(false)
    toggleBypass()
  }

  const handleStop = () => {
    if (!stopArmed) {
      setStopArmed(true)
      return
    }
    setStopArmed(false)
    onStop()
  }

  return (
    <header className="flex shrink-0 flex-col gap-2 border-b border-[#1c1f27] bg-[#0c0d11] px-3 py-2 xl:flex-row xl:items-center xl:px-4">
      <div className="flex min-w-0 items-center gap-3">
        <div className="flex shrink-0 items-center gap-2">
          <span className="inline-block h-2.5 w-2.5 rounded-full bg-emerald-400" aria-hidden="true" />
          <span className="text-sm font-semibold tracking-tight text-white">AutoMix</span>
          <span className="hidden text-[10px] uppercase tracking-widest text-zinc-500 2xl:inline">Broadcast</span>
        </div>

        <div
          role="status"
          aria-live="polite"
          className={`flex min-w-0 items-center gap-1.5 truncate rounded-md border px-2 py-1 text-[11px] ${
            sceneTransition
              ? transitionHold
                ? 'border-amber-500/40 bg-amber-500/10 text-amber-200'
                : 'border-cyan-500/40 bg-cyan-500/10 text-cyan-200'
              : 'border-transparent bg-[#15181f] text-zinc-400'
          }`}
        >
          {sceneTransition && (
            <span
              className={`inline-block h-1.5 w-1.5 shrink-0 rounded-full ${
                transitionHold ? 'bg-amber-400' : 'animate-pulse bg-cyan-400'
              }`}
              aria-hidden="true"
            />
          )}
          <span className="truncate">
            {mode === 'mic' ? 'Live Mic' : 'Synthetic Stage'} · {SCENES[sceneId].name}
            {sceneTransition && (
              <span className="font-semibold">
                {transitionHold ? ` · HELD BY ${transitionHold}` : ' · SCENE SETTLING'}
              </span>
            )}
          </span>
        </div>

        <div className="ml-auto flex shrink-0 items-center gap-2 tnum text-[11px] text-zinc-400 sm:gap-3">
          <Readout label="SHORT" value={`${fmtLufs(short)}`} unit="LUFS" />
          <Readout label="INTEG" value={`${fmtLufs(integ)}`} unit="LUFS" />
          <Readout label="TP" value={`${tp <= -90 ? '—' : tp.toFixed(1)}`} unit="dBTP" warn={tp > -1} />
        </div>

        <div role="status" aria-live="polite" className={`hidden shrink-0 items-center gap-1 text-[11px] sm:flex ${statusColor}`}>
          <span className="inline-block h-1.5 w-1.5 rounded-full bg-current" aria-hidden="true" />
          {status === 'ok' ? 'Brain OK' : status === 'stalled' ? 'Stalled' : 'Error'}
        </div>
      </div>

      <nav aria-label="Mixer state and safety controls" className="flex min-w-0 items-center gap-1.5 overflow-x-auto pb-0.5 xl:ml-auto xl:pb-0">
        <div role="status" aria-live="polite" className={`mr-1 flex shrink-0 items-center gap-1 text-[11px] sm:hidden ${statusColor}`}>
          <span className="inline-block h-1.5 w-1.5 rounded-full bg-current" aria-hidden="true" />
          {status === 'ok' ? 'Brain OK' : status === 'stalled' ? 'Stalled' : 'Error'}
        </div>

        <button
          onClick={handleSafe}
          aria-pressed={bypassed}
          aria-label={bypassed
            ? (safeReleaseArmed ? 'Confirm release of SAFE mode' : 'SAFE mode active. Press to begin release')
            : 'Engage SAFE mode'}
          className={`h-9 shrink-0 rounded-md px-3 text-xs font-semibold transition ${
            safeReleaseArmed
              ? 'bg-amber-500 text-black'
              : bypassed ? 'bg-red-600 text-white' : 'bg-[#15181f] text-red-300 hover:bg-[#1b1f28]'
          }`}
          title="SAFE uses a conservative static sum and stops autonomous changes"
        >
          {safeReleaseArmed ? 'CONFIRM RELEASE' : bypassed ? 'SAFE ACTIVE' : 'SAFE'}
        </button>

        <button
          onClick={() => toggleRecordingSessions(true)}
          className={`h-9 shrink-0 rounded-md px-3 text-xs font-semibold transition ${recording ? 'bg-red-600 text-white' : 'bg-[#15181f] text-cyan-300 hover:bg-[#1b1f28]'}`}
          title="Open the durable recording session library"
        >
          {recording ? '● Sessions' : 'Sessions'}
        </button>

        <button
          onClick={() => toggleDevices()}
          className={`h-9 shrink-0 rounded-md px-3 text-xs font-semibold transition ${showDevices ? 'bg-cyan-500 text-black' : 'bg-[#15181f] text-zinc-300 hover:bg-[#1b1f28]'}`}
          title="Choose the physical mic input and program output device"
        >
          Devices
        </button>

        <button
          onClick={() => togglePatch()}
          className={`h-9 shrink-0 rounded-md px-3 text-xs font-semibold transition ${showPatch ? 'bg-cyan-500 text-black' : 'bg-[#15181f] text-cyan-300 hover:bg-[#1b1f28]'}`}
          title="Assign which physical input feeds each channel"
        >
          Patch
        </button>

        <ModeToggle mixMode={mixMode} setMixMode={setMixMode} />

        <button
          onClick={toggleFreeze}
          aria-pressed={frozen}
          className={`h-9 shrink-0 rounded-md px-3 text-xs font-semibold transition ${
            frozen ? 'bg-amber-500 text-black' : 'bg-[#15181f] text-amber-300 hover:bg-[#1b1f28]'
          }`}
          title="Lock all AI parameters at their current values"
        >
          {frozen ? 'FROZEN' : 'FREEZE'}
        </button>

        <button
          onClick={handleStop}
          aria-label={stopArmed ? 'Confirm stop audio engine' : 'Stop audio engine'}
          className={`ml-1 h-9 shrink-0 rounded-md px-2.5 text-xs ${
            stopArmed ? 'bg-red-600 text-white' : 'bg-[#15181f] text-zinc-400 hover:bg-[#1b1f28]'
          }`}
        >
          {stopArmed ? 'CONFIRM STOP' : 'Stop'}
        </button>
      </nav>
    </header>
  )
}

function ModeToggle({ mixMode, setMixMode }: { mixMode: 'soundcheck' | 'live'; setMixMode: (m: 'soundcheck' | 'live') => void }) {
  return (
    <div className="flex h-9 shrink-0 overflow-hidden rounded-md border border-[#232733] text-[11px]">
      {(['soundcheck', 'live'] as const).map((m) => (
        <button
          key={m}
          onClick={() => setMixMode(m)}
          aria-pressed={mixMode === m}
          className={`px-2.5 font-medium transition ${
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
    <div className="flex flex-col items-end leading-none" aria-label={`${label} ${value} ${unit}`}>
      <span className="text-[9px] uppercase tracking-wider text-zinc-500">{label}</span>
      <span className={warn ? 'text-red-400' : 'text-zinc-200'}>
        {value} <span className="text-[9px] text-zinc-500">{unit}</span>
      </span>
    </div>
  )
}

function fmtLufs(v: number) {
  return v <= -90 || !isFinite(v) ? '—' : v.toFixed(1)
}
