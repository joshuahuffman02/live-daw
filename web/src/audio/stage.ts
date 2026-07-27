// The default church-stage inputs. In the appliance these are the raw Dante flows;
// here each is a synthesized stand-in. `label` is the Dante transmitter channel name
// (what the appliance would read over the Dante API to pre-name/pre-classify a
// channel before any audio arrives). The brain still classifies from audio and can
// disagree (showing low confidence).

import type { SourceClass } from '../types'

export interface StageChannelDef {
  id: number
  name: string // channel-slot default name ("Ch 1")
  label: string // Dante transmitter channel name (the physical input's name)
  kind: string // synth kind
  trueClass: SourceClass
  level: number // synth output level
}

export const STAGE: StageChannelDef[] = [
  { id: 1, name: 'Ch 1', label: 'Pastor Lav', kind: 'speech', trueClass: 'speech', level: 0.30 },
  { id: 2, name: 'Ch 2', label: 'Host Mic', kind: 'speech', trueClass: 'speech', level: 0.26 },
  { id: 3, name: 'Ch 3', label: 'Lead Vox', kind: 'leadVocal', trueClass: 'leadVocal', level: 0.30 },
  { id: 4, name: 'Ch 4', label: 'BGV 1', kind: 'bgv', trueClass: 'bgv', level: 0.22 },
  { id: 5, name: 'Ch 5', label: 'Acoustic DI', kind: 'acoustic', trueClass: 'acousticGuitar', level: 0.24 },
  { id: 6, name: 'Ch 6', label: 'Elec 57', kind: 'electric', trueClass: 'electricGuitar', level: 0.22 },
  { id: 7, name: 'Ch 7', label: 'Bass DI', kind: 'bass', trueClass: 'bass', level: 0.30 },
  { id: 8, name: 'Ch 8', label: 'Kick In', kind: 'kick', trueClass: 'kick', level: 0.34 },
  { id: 9, name: 'Ch 9', label: 'Keys', kind: 'keys', trueClass: 'keys', level: 0.24 },
  { id: 10, name: 'Ch 10', label: 'Tracks L/R', kind: 'tracks', trueClass: 'keys', level: 0.18 }, // stereo playback
]

// the two channel slots pre-wired into the speech automix bus
export const SPEECH_CHANNEL_IDS = [1, 2]
