// Shared types for the autonomous broadcast mixer.

export type SourceClass =
  | 'speech'
  | 'leadVocal'
  | 'bgv'
  | 'acousticGuitar'
  | 'electricGuitar'
  | 'bass'
  | 'kick'
  | 'keys'
  | 'unknown'

export type BusId = 'drums' | 'band' | 'vocals' | 'speech' | 'master'

export type SceneId =
  | 'preservice'
  | 'worship'
  | 'sermon'
  | 'prayer'
  | 'postservice'

// Parameters the operator can take manual control of (freezes the brain off it).
export type ParamKey =
  | 'label'
  | 'trim'
  | 'hpf'
  | 'gate'
  | 'eq'
  | 'comp'
  | 'fader'
  | 'pan'
  | 'reverb'
  | 'deess'

export interface EqBand {
  type: BiquadFilterType
  freq: number
  gainDb: number
  q: number
  kind: 'corrective' | 'voicing' | 'deess' | 'mask'
}

// One mixer channel as the UI/brain sees it (the "display + decision" model).
export interface ChannelModel {
  id: number
  name: string
  cls: SourceClass
  confidence: number // 0..1
  labelLocked: boolean
  bus: BusId
  isSpeech: boolean

  // measured (updated at a throttled rate for display)
  preRmsDb: number
  postRmsDb: number
  noiseFloorDb: number

  // input section
  polarityInv: boolean
  inputDelayMs: number
  muted: boolean
  soloed: boolean
  clip: boolean
  dca: number // 0 = none, 1..3 = DCA group
  muteGroup: number // 0 = none, 1..4
  sceneSafe: boolean // scene recalls won't touch this channel
  isStereo: boolean

  // current parameter values (what the engine is actually doing)
  trimDb: number
  hpfHz: number
  gateThreshDb: number
  gateOpen: boolean
  gateGrDb: number
  compThreshDb: number
  compRatio: number
  compGrDb: number
  faderDb: number
  pan: number
  reverbSendDb: number
  delaySendDb: number
  deEssDb: number
  eqBands: EqBand[]
  automixGainDb: number

  overrides: Partial<Record<ParamKey, boolean>>
  reason: string
  active: boolean
}

export interface MasterModel {
  momentaryLufs: number
  shortLufs: number
  integratedLufs: number
  truePeakDb: number
  limiterGrDb: number
  targetLufs: number
  ceilingDb: number
  glueGrDb: number
  correlation: number // -1..+1 phase correlation (mono-compatibility)
  clip: boolean
}

// matrix outputs: independently-balanced feeds derived from the mix
export type MatrixId = 'stream' | 'record' | 'assist' | 'mixminus'

export interface MatrixOut {
  id: MatrixId
  name: string
  blurb: string
  targetLufs: number
  momentaryLufs: number
}

export type MonitorSource = 'program' | 'solo' | MatrixId

export interface RecallScope {
  levels: boolean
  eq: boolean
  dynamics: boolean
  routing: boolean
}

export interface OscillatorConfig {
  on: boolean
  type: 'tone' | 'pink'
  dest: 'master' | number // master or channel id
  levelDb: number
}

export interface DcaGroup {
  id: number
  name: string
  levelDb: number
}

export type MixMode = 'soundcheck' | 'live'

export interface PlanItem {
  id: string
  title: string
  scene: SceneId
  /** spoken vs sung, for the log */
  kind: 'music' | 'spoken' | 'ambient'
}
