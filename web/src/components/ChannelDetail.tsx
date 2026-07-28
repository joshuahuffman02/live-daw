import { useStore } from '../store'
import { PROFILES } from '../brain/targets'

export default function ChannelDetail() {
  const id = useStore((s) => s.selectedChannel)
  const ch = useStore((s) => s.channels.find((c) => c.id === id))
  const dcaGroups = useStore((s) => s.dcaGroups)
  const setChannelField = useStore((s) => s.setChannelField)
  const setSend = useStore((s) => s.setSend)
  const setOverride = useStore((s) => s.setOverride)
  const toggleSceneSafe = useStore((s) => s.toggleSceneSafe)
  const copyChannel = useStore((s) => s.copyChannel)
  const pasteChannel = useStore((s) => s.pasteChannel)
  const clipboard = useStore((s) => s.clipboard)
  const commit = useStore((s) => s.commit)
  const select = useStore((s) => s.select)

  if (!ch) {
    return (
      <div className="rounded-lg border border-[#1c1f27] bg-[#101218] p-3 text-[11px] text-zinc-500">
        Select a channel to edit its input section, sends, and routing.
      </div>
    )
  }

  const sendDb = (which: 'reverb' | 'delay', db: number) => {
    if (!ch.overrides.reverb) { commit(); setOverride(ch.id, 'reverb', true) }
    setSend(ch.id, which, db)
  }

  return (
    <div className="rounded-lg border border-cyan-500/30 bg-[#101218] p-3">
      <div className="mb-2 flex items-center justify-between">
        <span className="text-xs font-semibold uppercase tracking-wider text-zinc-200">
          {PROFILES[ch.cls].label} <span className="text-zinc-600">· {ch.name}</span>
        </span>
        <button onClick={() => select(null)} aria-label={`Close details for ${ch.name}`} className="text-zinc-500 hover:text-zinc-300">×</button>
      </div>

      {/* input section */}
      <Section title="Input">
        <div className="flex items-center gap-2">
          <Toggle label="Ø Polarity" on={ch.polarityInv} onClick={() => { commit(); setChannelField(ch.id, { polarityInv: !ch.polarityInv }) }} />
          <Toggle label="Scene-safe" on={ch.sceneSafe} color="emerald" onClick={() => { commit(); toggleSceneSafe(ch.id) }} />
        </div>
        <Slider label="Delay" ariaLabel={`Input delay for ${ch.name}`} value={ch.inputDelayMs} min={0} max={30} step={0.1} unit="ms"
          onChange={(v) => setChannelField(ch.id, { inputDelayMs: v })} fmt={(v) => v.toFixed(1)} />
      </Section>

      {/* sends */}
      <Section title={`FX Sends ${ch.overrides.reverb ? '· MANUAL' : '· auto'}`}>
        <Slider label="Reverb" ariaLabel={`Reverb send for ${ch.name}`} value={ch.reverbSendDb} min={-60} max={0} step={1} unit="dB"
          onChange={(v) => sendDb('reverb', v)} fmt={fmtDb} />
        <Slider label="Delay" ariaLabel={`Delay send for ${ch.name}`} value={ch.delaySendDb} min={-60} max={0} step={1} unit="dB"
          onChange={(v) => sendDb('delay', v)} fmt={fmtDb} />
        {ch.overrides.reverb && (
          <button onClick={() => { commit(); setOverride(ch.id, 'reverb', false) }} className="mt-1 w-full rounded bg-[#1a1d25] py-1 text-[10px] text-cyan-300 hover:bg-[#222631]">↩ return sends to AUTO</button>
        )}
      </Section>

      {/* routing */}
      <Section title="Routing">
        <Row label="DCA group">
          <select value={ch.dca} onChange={(e) => { commit(); setChannelField(ch.id, { dca: +e.target.value }) }}
            aria-label={`DCA group for ${ch.name}`}
            className="rounded border border-[#232733] bg-[#0c0d11] px-1 py-0.5 text-[11px] text-zinc-300">
            <option value={0}>None</option>
            {dcaGroups.map((d) => <option key={d.id} value={d.id}>{d.id} · {d.name}</option>)}
          </select>
        </Row>
        <Row label="Mute group">
          <select value={ch.muteGroup} onChange={(e) => { commit(); setChannelField(ch.id, { muteGroup: +e.target.value }) }}
            aria-label={`Mute group for ${ch.name}`}
            className="rounded border border-[#232733] bg-[#0c0d11] px-1 py-0.5 text-[11px] text-zinc-300">
            <option value={0}>None</option>
            {[1, 2, 3, 4].map((g) => <option key={g} value={g}>Group {g}</option>)}
          </select>
        </Row>
        <Row label="Bus"><span className="text-[11px] text-zinc-400">{ch.bus}{ch.isSpeech ? ' · automix' : ''}</span></Row>
      </Section>

      <div className="mt-2 flex gap-1">
        <button onClick={() => copyChannel(ch.id)} className="flex-1 rounded bg-[#1a1d25] py-1 text-[10px] text-zinc-300 hover:bg-[#222631]">Copy</button>
        <button disabled={!clipboard} onClick={() => { commit(); pasteChannel(ch.id) }}
          className="flex-1 rounded bg-[#1a1d25] py-1 text-[10px] text-zinc-300 hover:bg-[#222631] disabled:opacity-30">Paste</button>
      </div>
    </div>
  )
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="mb-2">
      <div className="mb-1 text-[10px] uppercase tracking-wider text-zinc-500">{title}</div>
      <div className="flex flex-col gap-1.5">{children}</div>
    </div>
  )
}
function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return <div className="flex items-center justify-between"><span className="text-[11px] text-zinc-500">{label}</span>{children}</div>
}
function Toggle({ label, on, onClick, color = 'cyan' }: { label: string; on: boolean; onClick: () => void; color?: string }) {
  const active = color === 'emerald' ? 'bg-emerald-500 text-black' : 'bg-cyan-500 text-black'
  return (
    <button onClick={onClick} aria-pressed={on} className={`flex-1 rounded px-1.5 py-1 text-[10px] font-medium transition ${on ? active : 'bg-[#1a1d25] text-zinc-400 hover:text-zinc-200'}`}>{label}</button>
  )
}
function Slider({ label, ariaLabel, value, min, max, step, unit, onChange, fmt }: {
  label: string; ariaLabel: string; value: number; min: number; max: number; step: number; unit: string; onChange: (v: number) => void; fmt: (v: number) => string
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="w-12 text-[10px] text-zinc-500">{label}</span>
      <input type="range" min={min} max={max} step={step} value={clampN(value, min, max)} onChange={(e) => onChange(parseFloat(e.target.value))} aria-label={ariaLabel} className="h-1 flex-1 accent-cyan-400" />
      <span className="tnum w-12 text-right text-[10px] text-zinc-300">{fmt(value)}<span className="text-zinc-600">{unit}</span></span>
    </div>
  )
}
const fmtDb = (v: number) => (v <= -59 ? '−∞' : v.toFixed(0))
const clampN = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, isFinite(v) ? v : lo))
