// Cross-channel masking (the v2 "beat a volunteer" feature). A channel's EQ now
// depends on what the OTHER channels are doing: in each contested frequency band the
// highest-priority source wins and the lower-priority sources that crowd the same
// band get a small complementary carve, so the important source stays clear. This is
// what a good engineer does instinctively (pull the guitar back at 3 kHz so the vocal
// cuts through) and what a volunteer rarely manages live.

import type { SourceClass } from '../types'

export interface MaskBand { name: string; lo: number; hi: number; hz: number; q: number }

// the two classic fights: low-mid "mud" and the 2-4 kHz vocal-intelligibility region
export const MASK_BANDS: MaskBand[] = [
  { name: 'low-mid', lo: 180, hi: 520, hz: 330, q: 1.5 },
  { name: 'presence', lo: 1800, hi: 4500, hz: 3000, q: 1.3 },
]

export interface MaskInput { id: number; cls: SourceClass; active: boolean; energy: number[] }
export interface MaskDecision { id: number; bandIdx: number; gainDb: number; winnerCls: SourceClass | null }

// band-specific priority — higher value wins the band and is never carved by a lower one.
function priority(cls: SourceClass, bandIdx: number, sermon: boolean): number {
  if (bandIdx === 1) {
    // presence: human voice must win for intelligibility
    const p: Record<SourceClass, number> = {
      speech: sermon ? 12 : 8, leadVocal: sermon ? 7 : 10, bgv: 6,
      acousticGuitar: 4, electricGuitar: 4, keys: 4, bass: 1, kick: 1, unknown: 2,
    }
    return p[cls]
  }
  // low-mid: the low instruments own the foundation; voices kept high so they aren't carved
  const p: Record<SourceClass, number> = {
    bass: 9, kick: 8, speech: sermon ? 8 : 6, leadVocal: 7, keys: 5,
    acousticGuitar: 4, electricGuitar: 4, bgv: 4, unknown: 2,
  }
  return p[cls]
}

export function computeMasking(inputs: MaskInput[], sermon: boolean, maxCarveDb = 3.5): Map<number, MaskDecision[]> {
  const out = new Map<number, MaskDecision[]>()
  for (let bi = 0; bi < MASK_BANDS.length; bi++) {
    const contenders = inputs.filter((i) => i.active && i.energy[bi] > 1e-6)
    if (contenders.length < 2) continue

    let win = contenders[0]
    for (const c of contenders) {
      const pc = priority(c.cls, bi, sermon)
      const pw = priority(win.cls, bi, sermon)
      if (pc > pw || (pc === pw && c.energy[bi] > win.energy[bi])) win = c
    }
    const pWin = priority(win.cls, bi, sermon)

    for (const c of contenders) {
      if (c.id === win.id) continue
      if (priority(c.cls, bi, sermon) >= pWin) continue
      // carve scales with how much this loser competes with the winner in the band
      const ratio = Math.min(1, c.energy[bi] / (win.energy[bi] + 1e-9))
      const carve = -maxCarveDb * Math.min(1, 0.35 + 0.65 * ratio)
      const arr = out.get(c.id) ?? []
      arr.push({ id: c.id, bandIdx: bi, gainDb: carve, winnerCls: win.cls })
      out.set(c.id, arr)
    }
  }
  return out
}
