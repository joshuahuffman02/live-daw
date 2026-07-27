// Planning Center Services integration. Pulls the order of service and maps each plan
// item to a scene, so scene changes are driven by the *actual plan* (high trust) rather
// than guessed from audio. All requests go through the same-origin `/pco` dev proxy,
// which injects the Personal Access Token server-side (see vite.config.ts). In the
// appliance the device makes these same calls.

import type { PlanItem, SceneId } from '../types'

// keyword/type heuristic — offline, deterministic. (An LLM could parse ambiguous plans
// at service-prep time; this covers the common cases without a network model.)
export function mapItemToScene(title: string, itemType: string): { scene: SceneId; kind: PlanItem['kind'] } {
  const t = (title || '').toLowerCase()
  if (itemType === 'song') return { scene: 'worship', kind: 'music' }
  if (/pre.?service|prelude|count\s?down|countdown|loop|walk.?in|pre.?roll|gathering/.test(t)) return { scene: 'preservice', kind: 'ambient' }
  if (/post.?service|dismiss|benediction|sending|exit|outro|go in peace/.test(t)) return { scene: 'postservice', kind: 'ambient' }
  if (/prayer|response|reflect|communion|confession|lord'?s supper/.test(t)) return { scene: 'prayer', kind: 'spoken' }
  if (/message|sermon|teaching|scripture|reading|testimony|baptism|homily/.test(t)) return { scene: 'sermon', kind: 'spoken' }
  if (/welcome|announce|offering|giving|greeting|host|emcee|m\.?c\.?|news/.test(t)) return { scene: 'sermon', kind: 'spoken' }
  if (/worship|praise|hymn|song|chorus|anthem/.test(t)) return { scene: 'worship', kind: 'music' }
  return { scene: 'sermon', kind: 'spoken' } // unknown spoken item — speech-forward is the safe default
}

interface RawItem { id?: string; attributes?: { title?: string; item_type?: string } }

export function parsePlanItems(data: RawItem[]): PlanItem[] {
  return data.map((it, i) => {
    const title = it.attributes?.title || 'Item'
    const itemType = it.attributes?.item_type || 'item'
    const { scene, kind } = mapItemToScene(title, itemType)
    return { id: it.id ?? `p${i}`, title, scene, kind }
  })
}

async function firstPlan(url: string): Promise<{ id: string; title: string } | null> {
  const r = await fetch(url)
  if (!r.ok) throw new Error(`PCO ${r.status}`)
  const j = await r.json()
  const p = j.data?.[0]
  if (!p) return null
  return { id: p.id, title: p.attributes?.title || p.attributes?.dates || 'Service plan' }
}

export async function fetchLivePlan(): Promise<{ planTitle: string; items: PlanItem[] }> {
  const stRes = await fetch('/pco/services/v2/service_types?per_page=25')
  if (stRes.status === 401) throw new Error('401 — set PCO_APP_ID / PCO_SECRET in web/.env')
  if (!stRes.ok) throw new Error(`PCO service_types ${stRes.status}`)
  const stJson = await stRes.json()
  const stId = (import.meta.env.VITE_PCO_SERVICE_TYPE_ID as string) || stJson.data?.[0]?.id
  if (!stId) throw new Error('No service types found on this account')

  let plan = await firstPlan(`/pco/services/v2/service_types/${stId}/plans?filter=future&per_page=1&order=sort_date`)
  if (!plan) plan = await firstPlan(`/pco/services/v2/service_types/${stId}/plans?per_page=1&order=-sort_date`)
  if (!plan) throw new Error('No plans found for this service type')

  const itemsRes = await fetch(`/pco/services/v2/service_types/${stId}/plans/${plan.id}/items?per_page=100`)
  if (!itemsRes.ok) throw new Error(`PCO items ${itemsRes.status}`)
  const itemsJson = await itemsRes.json()
  const items = parsePlanItems(itemsJson.data || [])
  if (!items.length) throw new Error('Plan has no items')
  return { planTitle: plan.title, items }
}

// PCO-shaped sample so the parse + scene-mapping path runs with no credentials.
export const SAMPLE_PCO_ITEMS: RawItem[] = [
  { id: '1', attributes: { title: 'Pre-Service Countdown', item_type: 'media' } },
  { id: '2', attributes: { title: 'Welcome & Call to Worship', item_type: 'item' } },
  { id: '3', attributes: { title: 'Build My Life', item_type: 'song' } },
  { id: '4', attributes: { title: 'Goodness of God', item_type: 'song' } },
  { id: '5', attributes: { title: 'Announcements & Giving', item_type: 'item' } },
  { id: '6', attributes: { title: 'Message — Rooted', item_type: 'item' } },
  { id: '7', attributes: { title: 'Prayer & Response', item_type: 'item' } },
  { id: '8', attributes: { title: 'Doxology', item_type: 'song' } },
  { id: '9', attributes: { title: 'Benediction & Dismissal', item_type: 'item' } },
]
