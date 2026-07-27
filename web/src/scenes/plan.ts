// Mock Planning Center Services plan. In the appliance this is pulled from the
// PCO API (the order of service already exists), and each item maps to a scene.
// This is what makes scene changes high-trust: the plan says "item 6 is the
// message" -> duck the band, run the speech automix -> instead of the AI guessing
// from audio.

import type { PlanItem } from '../types'

export const SERVICE_PLAN: PlanItem[] = [
  { id: 'p1', title: 'Pre-Service Loop', scene: 'preservice', kind: 'ambient' },
  { id: 'p2', title: 'Call to Worship — "Build My Life"', scene: 'worship', kind: 'music' },
  { id: 'p3', title: 'Song — "Goodness of God"', scene: 'worship', kind: 'music' },
  { id: 'p4', title: 'Welcome & Announcements', scene: 'sermon', kind: 'spoken' },
  { id: 'p5', title: 'Message — "Rooted"', scene: 'sermon', kind: 'spoken' },
  { id: 'p6', title: 'Prayer & Response', scene: 'prayer', kind: 'spoken' },
  { id: 'p7', title: 'Closing Song — "Doxology"', scene: 'worship', kind: 'music' },
  { id: 'p8', title: 'Dismissal', scene: 'postservice', kind: 'ambient' },
]
