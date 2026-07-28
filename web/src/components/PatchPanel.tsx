import { useCallback, useRef } from 'react'
import { useStore } from '../store'
import { useEngine } from '../state/engine-context'
import { PROFILES } from '../brain/targets'
import { useDialogFocusTrap } from '../hooks/useDialogFocusTrap'

// The input patch: assign which physical input (Dante flow) feeds each channel.
// Default is 1:1. In the appliance the input list comes from the Dante subscription
// and the names are read from the Dante transmitter labels.
export default function PatchPanel() {
  const engine = useEngine()
  const show = useStore((s) => s.showPatch)
  const channels = useStore((s) => s.channels)
  const inputs = useStore((s) => s.inputs)
  const patch = useStore((s) => s.patch)
  const setChannelPatch = useStore((s) => s.setChannelPatch)
  const setName = useStore((s) => s.setName)
  const setLabel = useStore((s) => s.setLabel)
  const togglePatch = useStore((s) => s.togglePatch)
  const commit = useStore((s) => s.commit)
  const pushLog = useStore((s) => s.pushLog)
  const dialogRef = useRef<HTMLDivElement>(null)
  const close = useCallback(() => togglePatch(false), [togglePatch])

  useDialogFocusTrap(show, dialogRef, close)

  if (!show) return null

  const patchTo = (channelId: number, inputId: number | null) => {
    commit()
    engine.patch(channelId, inputId)
    setChannelPatch(channelId, inputId)
    const inp = inputs.find((i) => i.id === inputId)
    setName(channelId, inp ? inp.name : '—')
    pushLog('override', `Patch: Ch ${channelId} ← ${inp ? inp.name : 'no input'}`)
  }

  const reset = () => {
    commit()
    channels.forEach((ch) => {
      const inId = inputs.some((i) => i.id === ch.id) ? ch.id : null
      engine.patch(ch.id, inId)
      setChannelPatch(ch.id, inId)
      const inp = inputs.find((i) => i.id === inId)
      if (inp) setName(ch.id, inp.name)
    })
    pushLog('override', 'Patch reset to 1:1')
  }

  const importDante = () => {
    commit()
    channels.forEach((ch) => {
      const inp = inputs.find((i) => i.id === patch[ch.id])
      if (inp) { setName(ch.id, inp.name); setLabel(ch.id, inp.defaultClass, true) }
    })
    pushLog('label', 'Imported Dante channel names → pre-named & locked channel labels')
  }

  // which inputs are unpatched (not feeding any channel)?
  const used = new Set(Object.values(patch).filter((v) => v !== null))

  return (
    <div className="absolute inset-0 z-20 flex items-center justify-center bg-black/70 p-3 sm:p-6">
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="patch-dialog-title"
        aria-describedby="patch-dialog-description"
        tabIndex={-1}
        className="max-h-full w-full max-w-[640px] overflow-hidden rounded-xl border border-[#232733] bg-[#0e1015] shadow-2xl outline-none"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[#1c1f27] px-4 py-3">
          <div>
            <h2 id="patch-dialog-title" className="text-sm font-semibold text-white">Input Patch</h2>
            <div id="patch-dialog-description" className="text-[11px] text-zinc-500">Assign a physical input (Dante flow) to each channel</div>
          </div>
          <div className="flex items-center gap-2">
            <button onClick={importDante} className="rounded bg-[#15181f] px-2.5 py-1.5 text-[11px] text-cyan-300 hover:bg-[#1b1f28]">Import Dante names</button>
            <button onClick={reset} className="rounded bg-[#15181f] px-2.5 py-1.5 text-[11px] text-zinc-300 hover:bg-[#1b1f28]">Reset 1:1</button>
            <button onClick={close} className="rounded bg-[#15181f] px-2.5 py-1.5 text-[11px] text-zinc-400 hover:bg-[#1b1f28]">Done</button>
          </div>
        </div>

        <div className="max-h-[60vh] overflow-y-auto p-3">
          <div className="grid grid-cols-[auto_1fr_auto] items-center gap-x-3 gap-y-1.5">
            <div className="text-[10px] uppercase tracking-wider text-zinc-500">Channel</div>
            <div className="text-[10px] uppercase tracking-wider text-zinc-500">Input (Dante flow)</div>
            <div className="text-[10px] uppercase tracking-wider text-zinc-500">Detected</div>
            {channels.map((ch) => {
              const inId = patch[ch.id] ?? null
              return (
                <Row key={ch.id} ch={ch} inId={inId} inputs={inputs} onPatch={patchTo} />
              )
            })}
          </div>

          {inputs.some((i) => !used.has(i.id)) && (
            <div className="mt-3 rounded border border-[#1c1f27] bg-[#0c0d11] p-2 text-[10px] text-zinc-500">
              Unpatched inputs: {inputs.filter((i) => !used.has(i.id)).map((i) => i.name).join(', ') || 'none'}
            </div>
          )}
          <div className="mt-3 text-[10px] leading-relaxed text-zinc-500">
            In the appliance the input list is the Dante subscription (set in Dante Controller / via the
            Dante API). Channel <span className="text-zinc-400">roles</span> (class, bus, automix) come from the
            classifier — confirm/lock them on the strip. <span className="text-cyan-400">Import Dante names</span>{' '}
            pre-names and pre-classifies every channel before any audio plays.
          </div>
        </div>
      </div>
    </div>
  )
}

function Row({ ch, inId, inputs, onPatch }: {
  ch: { id: number; cls: any; confidence: number }
  inId: number | null
  inputs: { id: number; name: string; stereo: boolean }[]
  onPatch: (channelId: number, inputId: number | null) => void
}) {
  return (
    <>
      <div className="tnum text-[12px] text-zinc-300">Ch {ch.id}</div>
      <select
        value={inId ?? 0}
        onChange={(e) => { const v = +e.target.value; onPatch(ch.id, v === 0 ? null : v) }}
        aria-label={`Input source for channel ${ch.id}`}
        className={`rounded border bg-[#0c0d11] px-2 py-1 text-[11px] ${inId === null ? 'border-red-500/40 text-red-300' : 'border-[#232733] text-zinc-200'}`}
      >
        <option value={0}>— no input —</option>
        {inputs.map((i) => <option key={i.id} value={i.id}>{i.name}{i.stereo ? ' (stereo)' : ''}</option>)}
      </select>
      <div className="text-right text-[11px] text-zinc-400">
        {PROFILES[ch.cls as keyof typeof PROFILES]?.label ?? '—'} <span className="text-zinc-500">{Math.round(ch.confidence * 100)}%</span>
      </div>
    </>
  )
}
