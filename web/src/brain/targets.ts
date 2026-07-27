// Per-source-class target profiles — the "voicing" the brain mixes toward.
// In the real appliance these target curves are LEARNED from your weekly
// approved mixes (the data flywheel). Here they are hand-authored reference
// curves so the demo runs with no training data; the interface is identical.

import type { BusId, SourceClass } from '../types'

export interface VoicingBand {
  type: BiquadFilterType
  freq: number
  gainDb: number
  q: number
}

export interface CompProfile {
  thresholdDb: number
  ratio: number
  attack: number // seconds
  release: number
  knee: number
}

export interface ClassProfile {
  label: string
  bus: BusId
  isSpeech: boolean
  hpfHz: number
  deEss: boolean
  // gate/expander
  gate: { enabled: boolean; ratio: number; rangeDb: number; offsetDb: number } // threshold = noiseFloor + offset
  comp: CompProfile
  voicing: VoicingBand[] // applied (scaled by confidence) as the tonal/auto-EQ stage
  pan: number
  // nominal post-strip target level (dBFS RMS) used by auto-leveling
  targetRmsDb: number
}

export const PROFILES: Record<SourceClass, ClassProfile> = {
  speech: {
    label: 'Speech',
    bus: 'speech',
    isSpeech: true,
    hpfHz: 100,
    deEss: true,
    gate: { enabled: false, ratio: 2, rangeDb: 10, offsetDb: 8 }, // automix handles dynamics
    comp: { thresholdDb: -26, ratio: 3.5, attack: 0.006, release: 0.18, knee: 8 },
    voicing: [
      { type: 'peaking', freq: 300, gainDb: -2.5, q: 1.1 }, // de-mud
      { type: 'peaking', freq: 3400, gainDb: 3.0, q: 1.0 }, // intelligibility presence
      { type: 'highshelf', freq: 9000, gainDb: 2.0, q: 0.7 },
    ],
    pan: 0,
    targetRmsDb: -20,
  },
  leadVocal: {
    label: 'Lead Vocal',
    bus: 'vocals',
    isSpeech: false,
    hpfHz: 90,
    deEss: true,
    gate: { enabled: false, ratio: 2, rangeDb: 8, offsetDb: 10 },
    comp: { thresholdDb: -24, ratio: 3.0, attack: 0.008, release: 0.16, knee: 10 },
    voicing: [
      { type: 'peaking', freq: 250, gainDb: -2.0, q: 1.0 },
      { type: 'peaking', freq: 3000, gainDb: 2.5, q: 0.9 },
      { type: 'highshelf', freq: 11000, gainDb: 2.5, q: 0.7 }, // air
    ],
    pan: 0,
    targetRmsDb: -18,
  },
  bgv: {
    label: 'BGV',
    bus: 'vocals',
    isSpeech: false,
    hpfHz: 120,
    deEss: true,
    gate: { enabled: false, ratio: 2, rangeDb: 8, offsetDb: 10 },
    comp: { thresholdDb: -26, ratio: 3.0, attack: 0.01, release: 0.18, knee: 10 },
    voicing: [
      { type: 'peaking', freq: 300, gainDb: -3.0, q: 1.0 }, // tuck behind lead
      { type: 'peaking', freq: 2500, gainDb: -1.0, q: 1.2 },
      { type: 'highshelf', freq: 10000, gainDb: 1.5, q: 0.7 },
    ],
    pan: 0.35,
    targetRmsDb: -24,
  },
  acousticGuitar: {
    label: 'Acoustic',
    bus: 'band',
    isSpeech: false,
    hpfHz: 90,
    deEss: false,
    gate: { enabled: false, ratio: 2, rangeDb: 12, offsetDb: 10 },
    comp: { thresholdDb: -22, ratio: 2.5, attack: 0.012, release: 0.2, knee: 8 },
    voicing: [
      { type: 'peaking', freq: 200, gainDb: -3.0, q: 1.1 }, // boom
      { type: 'peaking', freq: 2500, gainDb: 1.5, q: 0.9 },
      { type: 'highshelf', freq: 9000, gainDb: 1.5, q: 0.7 },
    ],
    pan: -0.3,
    targetRmsDb: -22,
  },
  electricGuitar: {
    label: 'Electric',
    bus: 'band',
    isSpeech: false,
    hpfHz: 100,
    deEss: false,
    gate: { enabled: true, ratio: 4, rangeDb: 14, offsetDb: 12 },
    comp: { thresholdDb: -20, ratio: 2.5, attack: 0.015, release: 0.18, knee: 6 },
    voicing: [
      { type: 'peaking', freq: 400, gainDb: -2.0, q: 1.2 },
      { type: 'peaking', freq: 1800, gainDb: 1.0, q: 1.0 },
      { type: 'lowpass', freq: 9000, gainDb: 0, q: 0.7 },
    ],
    pan: 0.3,
    targetRmsDb: -22,
  },
  bass: {
    label: 'Bass',
    bus: 'band',
    isSpeech: false,
    hpfHz: 35,
    deEss: false,
    gate: { enabled: false, ratio: 2, rangeDb: 10, offsetDb: 10 },
    comp: { thresholdDb: -20, ratio: 3.5, attack: 0.02, release: 0.12, knee: 6 },
    voicing: [
      { type: 'peaking', freq: 80, gainDb: 1.5, q: 0.9 },
      { type: 'peaking', freq: 700, gainDb: 1.0, q: 1.0 }, // string definition on phones
      { type: 'lowpass', freq: 6000, gainDb: 0, q: 0.7 },
    ],
    pan: 0,
    targetRmsDb: -20,
  },
  kick: {
    label: 'Kick',
    bus: 'drums',
    isSpeech: false,
    hpfHz: 30,
    deEss: false,
    gate: { enabled: true, ratio: 6, rangeDb: 18, offsetDb: 14 },
    comp: { thresholdDb: -18, ratio: 4, attack: 0.004, release: 0.1, knee: 4 },
    voicing: [
      { type: 'peaking', freq: 60, gainDb: 2.0, q: 1.0 }, // weight
      { type: 'peaking', freq: 400, gainDb: -3.0, q: 1.3 }, // boxiness
      { type: 'peaking', freq: 3500, gainDb: 2.0, q: 1.0 }, // beater on phones
    ],
    pan: 0,
    targetRmsDb: -20,
  },
  keys: {
    label: 'Keys',
    bus: 'band',
    isSpeech: false,
    hpfHz: 60,
    deEss: false,
    gate: { enabled: false, ratio: 2, rangeDb: 10, offsetDb: 10 },
    comp: { thresholdDb: -24, ratio: 2.5, attack: 0.02, release: 0.25, knee: 10 },
    voicing: [
      { type: 'peaking', freq: 300, gainDb: -2.0, q: 1.0 },
      { type: 'highshelf', freq: 8000, gainDb: 1.0, q: 0.7 },
      { type: 'lowshelf', freq: 120, gainDb: -1.5, q: 0.7 },
    ],
    pan: -0.2,
    targetRmsDb: -24,
  },
  unknown: {
    label: 'Unknown',
    bus: 'band',
    isSpeech: false,
    hpfHz: 80,
    deEss: false,
    gate: { enabled: false, ratio: 2, rangeDb: 8, offsetDb: 12 },
    comp: { thresholdDb: -24, ratio: 2, attack: 0.02, release: 0.2, knee: 10 },
    voicing: [],
    pan: 0,
    targetRmsDb: -22,
  },
}
