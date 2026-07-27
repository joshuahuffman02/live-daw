// Scene layer. A scene is a snapshot of mix intent: DCA group offsets, per-class
// fader/reverb targets, whether the speech automix is active and forward, the
// master loudness target, and the reverb return level. The brain ramps toward the
// active scene (never jumps). Scenes are selected by the service plan (Planning
// Center), not guessed from audio.

import type { SceneId, SourceClass } from '../types'

export interface SceneClassTarget {
  faderDb?: number // offset applied to the class's base fader
  reverbSendDb?: number
}

export interface Scene {
  id: SceneId
  name: string
  blurb: string
  // DCA-style logical group offsets (dB), applied on top of channel faders
  dca: { band: number; vocals: number; speech: number }
  classTargets: Partial<Record<SourceClass, SceneClassTarget>>
  speechActive: boolean // automix members live + speech bus forward
  reverbReturnDb: number
  masterTargetLufs: number
}

const OFF = -60

export const SCENES: Record<SceneId, Scene> = {
  preservice: {
    id: 'preservice',
    name: 'Pre-Service',
    blurb: 'Ambient bed. Band low, vocals & speech parked.',
    dca: { band: -10, vocals: OFF, speech: OFF },
    classTargets: {
      keys: { faderDb: -2, reverbSendDb: -10 },
      bass: { faderDb: -6 },
      kick: { faderDb: OFF },
    },
    speechActive: false,
    reverbReturnDb: -14,
    masterTargetLufs: -16,
  },
  worship: {
    id: 'worship',
    name: 'Worship',
    blurb: 'Vocal-forward, band up, reverb open. Speech automix idle.',
    dca: { band: 0, vocals: 0, speech: -8 },
    classTargets: {
      leadVocal: { faderDb: 2, reverbSendDb: -10 },
      bgv: { faderDb: -2, reverbSendDb: -8 },
      kick: { faderDb: 0 },
      bass: { faderDb: 0 },
    },
    speechActive: false,
    reverbReturnDb: -9,
    masterTargetLufs: -14,
  },
  sermon: {
    id: 'sermon',
    name: 'Sermon',
    blurb: 'Speech automix live & forward. Band ducked under the message.',
    dca: { band: -16, vocals: -18, speech: 0 },
    classTargets: {
      speech: { faderDb: 2, reverbSendDb: OFF },
      keys: { faderDb: -8, reverbSendDb: -16 }, // soft pad bed only
      kick: { faderDb: OFF },
      bass: { faderDb: -10 },
    },
    speechActive: true,
    reverbReturnDb: -20,
    masterTargetLufs: -15,
  },
  prayer: {
    id: 'prayer',
    name: 'Prayer & Response',
    blurb: 'Speech softer & intimate, gentle pad underneath.',
    dca: { band: -14, vocals: -10, speech: -3 },
    classTargets: {
      speech: { faderDb: 0, reverbSendDb: -18 },
      keys: { faderDb: -6, reverbSendDb: -12 },
      leadVocal: { faderDb: -4, reverbSendDb: -8 },
      kick: { faderDb: OFF },
      bass: { faderDb: -12 },
    },
    speechActive: true,
    reverbReturnDb: -12,
    masterTargetLufs: -15,
  },
  postservice: {
    id: 'postservice',
    name: 'Post-Service',
    blurb: 'Back to an ambient bed as people leave.',
    dca: { band: -8, vocals: OFF, speech: OFF },
    classTargets: {
      keys: { faderDb: -2, reverbSendDb: -10 },
      bass: { faderDb: -6 },
      kick: { faderDb: OFF },
    },
    speechActive: false,
    reverbReturnDb: -14,
    masterTargetLufs: -16,
  },
}
