import { useStore } from '../store'
import { SERVICE_PLAN } from '../scenes/plan'
import { SCENES } from '../scenes/scenes'
import { fetchLivePlan, parsePlanItems, SAMPLE_PCO_ITEMS } from '../scenes/pco'
import type { PlanItem } from '../types'

export default function SceneTimeline() {
  const planIndex = useStore((s) => s.planIndex)
  const setPlanIndex = useStore((s) => s.setPlanIndex)
  const setScene = useStore((s) => s.setScene)
  const commit = useStore((s) => s.commit)
  const livePlan = useStore((s) => s.livePlan)
  const pcoStatus = useStore((s) => s.pcoStatus)
  const pcoPlanTitle = useStore((s) => s.pcoPlanTitle)
  const pcoError = useStore((s) => s.pcoError)
  const setPco = useStore((s) => s.setPco)
  const setLivePlan = useStore((s) => s.setLivePlan)
  const pushLog = useStore((s) => s.pushLog)

  const plan = livePlan ?? SERVICE_PLAN

  function go(i: number) {
    if (i < 0 || i >= plan.length) return
    commit()
    setPlanIndex(i)
    setScene(plan[i].scene)
  }

  function loadPlanItems(items: PlanItem[], title: string, src: string) {
    commit()
    setLivePlan(items)
    setPlanIndex(0)
    setScene(items[0].scene)
    pushLog('scene', `Loaded ${src} plan: "${title}" (${items.length} items)`)
  }

  async function connect() {
    setPco({ pcoStatus: 'connecting', pcoError: null })
    try {
      const { planTitle, items } = await fetchLivePlan()
      loadPlanItems(items, planTitle, 'Planning Center')
      setPco({ pcoStatus: 'connected', pcoPlanTitle: planTitle, pcoError: null })
    } catch (e) {
      setPco({ pcoStatus: 'error', pcoError: (e as Error).message })
      pushLog('safety', `Planning Center: ${(e as Error).message}`)
    }
  }

  function loadSample() {
    const items = parsePlanItems(SAMPLE_PCO_ITEMS)
    loadPlanItems(items, 'Sample Service (offline)', 'Sample')
    setPco({ pcoStatus: 'connected', pcoPlanTitle: 'Sample Service (offline)', pcoError: null })
  }

  function disconnect() {
    commit()
    setLivePlan(null)
    setPco({ pcoStatus: 'idle', pcoPlanTitle: null, pcoError: null })
    setPlanIndex(0)
    setScene(SERVICE_PLAN[0].scene)
    pushLog('scene', 'Reverted to built-in sample plan')
  }

  const connected = !!livePlan

  return (
    <nav aria-label="Service plan" className="flex min-w-0 shrink-0 items-center gap-2 overflow-hidden border-b border-[#1c1f27] bg-[#0a0b0e] px-2 py-2 sm:px-3">
      {/* Planning Center control */}
      <div className="flex shrink-0 items-center gap-1.5 pr-2">
        <PcoGlyph connected={connected} />
        {connected ? (
          <>
            <span className="max-w-[160px] truncate text-[11px] font-medium text-white" title={pcoPlanTitle ?? ''}>{pcoPlanTitle}</span>
            <button onClick={disconnect} className="rounded bg-[#15181f] px-1.5 py-0.5 text-[9px] text-zinc-400 hover:bg-[#1b1f28]">×</button>
          </>
        ) : (
          <>
            <button onClick={connect} disabled={pcoStatus === 'connecting'}
              className="rounded bg-[#15181f] px-2 py-1 text-[10px] font-medium text-cyan-300 hover:bg-[#1b1f28] disabled:opacity-50">
              {pcoStatus === 'connecting' ? 'Connecting…' : <><span className="hidden sm:inline">Connect Planning Center</span><span className="sm:hidden">Plan</span></>}
            </button>
            <button onClick={loadSample} className="hidden rounded bg-[#15181f] px-2 py-1 text-[10px] text-zinc-400 hover:bg-[#1b1f28] sm:block" title="Run the parser on a sample PCO plan (no credentials)">sample</button>
          </>
        )}
        {pcoStatus === 'error' && (
          <span role="alert" title={pcoError ?? ''} className="max-w-[190px] truncate text-[10px] text-red-300">
            <span className="sm:hidden">PCO unavailable</span>
            <span className="hidden sm:inline">PCO unavailable · {friendlyPcoError(pcoError)}</span>
          </span>
        )}
      </div>

      <div className="h-5 w-px bg-[#1c1f27]" />

      <button onClick={() => go(planIndex - 1)} disabled={planIndex <= 0}
        aria-label="Previous service cue"
        className="rounded bg-[#15181f] px-2 py-1 text-xs text-zinc-400 hover:bg-[#1b1f28] disabled:opacity-30">‹</button>

      <div className="flex flex-1 items-center gap-1.5 overflow-x-auto">
        {plan.map((item, i) => {
          const active = i === planIndex
          const done = i < planIndex
          const sc = SCENES[item.scene]
          return (
            <button key={item.id} onClick={() => go(i)}
              aria-current={active ? 'step' : undefined}
              className={`flex shrink-0 items-center gap-2 rounded-md border px-2.5 py-1.5 text-left transition ${
                active ? 'border-cyan-500/60 bg-cyan-500/10'
                  : done ? 'border-[#1c1f27] bg-[#0c0d11] opacity-60'
                  : 'border-[#1c1f27] bg-[#0c0d11] hover:border-[#2a2e37]'}`}>
              <span className={`inline-block h-1.5 w-1.5 rounded-full ${active ? 'bg-cyan-400' : done ? 'bg-zinc-600' : 'bg-zinc-700'}`} />
              <span className="leading-tight">
                <span className={`block max-w-[180px] truncate text-[11px] font-medium ${active ? 'text-white' : 'text-zinc-300'}`}>{item.title}</span>
                <span className="block text-[9px] uppercase tracking-wider text-zinc-500">{sc.name} · {item.kind}</span>
              </span>
            </button>
          )
        })}
      </div>

      <button onClick={() => go(planIndex + 1)} disabled={planIndex >= plan.length - 1}
        aria-label="Next service cue"
        className="rounded bg-cyan-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-cyan-600 disabled:opacity-30">Next ›</button>
    </nav>
  )
}

function PcoGlyph({ connected }: { connected: boolean }) {
  return <span className={`inline-block h-2.5 w-2.5 rounded-sm ${connected ? 'bg-gradient-to-br from-emerald-400 to-cyan-600' : 'bg-gradient-to-br from-cyan-400 to-blue-600'}`} />
}

function friendlyPcoError(message: string | null) {
  const normalized = message?.toLowerCase() ?? ''
  if (normalized.includes('pco_app_id') || normalized.includes('pco_secret')) return 'credentials not configured'
  if (normalized.includes('401') || normalized.includes('unauthorized')) return 'authentication failed'
  if (normalized.includes('network') || normalized.includes('fetch')) return 'network request failed'
  return 'see operator log'
}
