import { useEffect } from 'react'
import { useStore } from '../store'
import { useEngine } from '../state/engine-context'

// Pick the exact physical audio devices: which microphone feeds the live channel, and
// which speaker/headset the program plays out of. (In the appliance this is the Dante
// device + clock; in the browser it's the OS input/output devices.)
export default function DevicesPanel() {
  const engine = useEngine()
  const show = useStore((s) => s.showDevices)
  const mode = useStore((s) => s.mode)
  const devices = useStore((s) => s.devices)
  const inputDeviceId = useStore((s) => s.inputDeviceId)
  const outputDeviceId = useStore((s) => s.outputDeviceId)
  const setDevices = useStore((s) => s.setDevices)
  const setInputDeviceId = useStore((s) => s.setInputDeviceId)
  const setOutputDeviceId = useStore((s) => s.setOutputDeviceId)
  const toggleDevices = useStore((s) => s.toggleDevices)
  const pushLog = useStore((s) => s.pushLog)

  async function refresh() {
    const d = await engine.listDevices()
    setDevices(d)
    if (mode === 'mic') setInputDeviceId(engine.micDeviceId())
  }

  useEffect(() => {
    if (show) refresh()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [show])

  if (!show) return null

  const labelOf = (list: { deviceId: string; label: string }[], id: string | null) =>
    list.find((x) => x.deviceId === id)?.label ?? id ?? '—'

  async function chooseInput(id: string) {
    try {
      await engine.setMicInput(id)
      setInputDeviceId(engine.micDeviceId() ?? id)
      pushLog('info', `Mic input → ${labelOf(devices.inputs, id)}`)
      refresh()
    } catch (e) {
      pushLog('safety', `Mic device error: ${(e as Error).message}`)
    }
  }
  async function chooseOutput(id: string) {
    await engine.setOutputDevice(id)
    setOutputDeviceId(id)
    pushLog('info', `Output → ${labelOf(devices.outputs, id)}`)
  }

  const labelsHidden = devices.inputs.some((d) => /^Microphone \d/.test(d.label)) || devices.outputs.some((d) => /^Output \d/.test(d.label))

  return (
    <div className="absolute inset-0 z-20 flex items-center justify-center bg-black/60 p-6" onClick={() => toggleDevices(false)}>
      <div className="w-[460px] overflow-hidden rounded-xl border border-[#232733] bg-[#0e1015] shadow-2xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between border-b border-[#1c1f27] px-4 py-3">
          <div>
            <div className="text-sm font-semibold text-white">Audio Devices</div>
            <div className="text-[11px] text-zinc-500">Choose the exact mic and output</div>
          </div>
          <div className="flex items-center gap-2">
            <button onClick={refresh} className="rounded bg-[#15181f] px-2.5 py-1.5 text-[11px] text-zinc-300 hover:bg-[#1b1f28]">Refresh</button>
            <button onClick={() => toggleDevices(false)} className="rounded bg-[#15181f] px-2.5 py-1.5 text-[11px] text-zinc-400 hover:bg-[#1b1f28]">Done</button>
          </div>
        </div>

        <div className="flex flex-col gap-3 p-4">
          {/* input */}
          <div>
            <div className="mb-1 text-[9px] uppercase tracking-wider text-zinc-600">Microphone input</div>
            {mode === 'mic' ? (
              <select value={inputDeviceId ?? ''} onChange={(e) => chooseInput(e.target.value)}
                className="w-full rounded border border-[#232733] bg-[#0c0d11] px-2 py-1.5 text-[12px] text-zinc-200">
                {devices.inputs.length === 0 && <option value="">No inputs found</option>}
                {devices.inputs.map((d) => <option key={d.deviceId} value={d.deviceId}>{d.label}</option>)}
              </select>
            ) : (
              <div className="rounded border border-[#1c1f27] bg-[#0c0d11] px-2 py-1.5 text-[11px] text-zinc-500">
                Synthetic stage — no live mic. Restart in <span className="text-zinc-300">Live Microphone</span> mode to choose a mic.
              </div>
            )}
          </div>

          {/* output */}
          <div>
            <div className="mb-1 text-[9px] uppercase tracking-wider text-zinc-600">Program output</div>
            {devices.canSetSink ? (
              <select value={outputDeviceId ?? ''} onChange={(e) => chooseOutput(e.target.value)}
                className="w-full rounded border border-[#232733] bg-[#0c0d11] px-2 py-1.5 text-[12px] text-zinc-200">
                <option value="">System default</option>
                {devices.outputs.map((d) => <option key={d.deviceId} value={d.deviceId}>{d.label}</option>)}
              </select>
            ) : (
              <div className="rounded border border-[#1c1f27] bg-[#0c0d11] px-2 py-1.5 text-[11px] text-amber-400/80">
                This browser can't switch the output device (Web Audio <span className="font-mono">setSinkId</span> unsupported). Pick the output in your OS sound settings — Safari notably lacks this.
              </div>
            )}
          </div>

          {labelsHidden && (
            <div className="rounded border border-[#1c1f27] bg-[#0c0d11] p-2 text-[10px] text-zinc-500">
              Device names are hidden until mic access is granted — start in <span className="text-zinc-300">Live Microphone</span> mode to see real names (e.g. “AirPods Pro”).
            </div>
          )}
          <div className="text-[10px] leading-relaxed text-zinc-600">
            macOS tip: if it grabbed your iPhone, that's Continuity — pick your AirPods (or interface) above. The
            appliance instead opens the <span className="text-zinc-400">Dante</span> device and follows the network leader clock.
          </div>
        </div>
      </div>
    </div>
  )
}
