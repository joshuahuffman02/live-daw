import { create } from 'zustand'
import type {
  ChannelModel, MasterModel, MixMode, ParamKey, SceneId, SourceClass,
  MonitorSource, MatrixOut, RecallScope, OscillatorConfig, DcaGroup, PlanItem,
} from './types'
import type { InputMode } from './audio/engine'
import type { BrowserRecordingSession } from './recording/session-library'

export interface LogEntry {
  id: number
  t: number
  kind: 'scene' | 'label' | 'override' | 'safety' | 'eq' | 'info'
  text: string
}

export interface SceneTransition {
  from: SceneId
  to: SceneId
  startedAtMs: number
}

let logId = 0

// snapshot of operator-controlled state for undo/redo
interface UndoSnap {
  channels: ChannelModel[]
  sceneId: SceneId
  dcaGroups: DcaGroup[]
  recallScope: RecallScope
}

export interface MixerState {
  started: boolean
  mode: InputMode
  channels: ChannelModel[]
  master: MasterModel
  sceneId: SceneId
  sceneTransition: SceneTransition | null
  planIndex: number
  mixMode: MixMode
  frozen: boolean
  bypassed: boolean
  brainStatus: 'ok' | 'stalled' | 'error'
  selectedChannel: number | null
  log: LogEntry[]

  // console additions
  monitorSource: MonitorSource
  dcaGroups: DcaGroup[]
  muteGroups: boolean[] // active state of 4 mute groups
  matrix: MatrixOut[]
  mixMinusChannelId: number | null
  recallScope: RecallScope
  oscillator: OscillatorConfig
  recording: boolean
  recElapsed: number
  recordingSessions: BrowserRecordingSession[]
  activeRecordingSessionId: string | null
  selectedRecordingSessionId: string | null
  recordingLibraryStatus: string
  recordingError: string | null
  showRecordingSessions: boolean
  clipboard: Partial<ChannelModel> | null
  undoDepth: number
  redoDepth: number

  // input patch
  inputs: { id: number; name: string; defaultClass: SourceClass; stereo: boolean }[]
  patch: Record<number, number | null> // channelId -> inputId
  showPatch: boolean

  // Planning Center
  pcoStatus: 'idle' | 'connecting' | 'connected' | 'error'
  pcoPlanTitle: string | null
  pcoError: string | null
  livePlan: PlanItem[] | null

  // audio devices
  devices: { inputs: { deviceId: string; label: string }[]; outputs: { deviceId: string; label: string }[]; canSetSink: boolean }
  inputDeviceId: string | null
  outputDeviceId: string | null
  showDevices: boolean

  setStarted: (b: boolean, mode: InputMode) => void
  initChannels: (c: ChannelModel[]) => void
  setChannels: (c: ChannelModel[]) => void
  patchChannel: (id: number, patch: Partial<ChannelModel>) => void
  setMaster: (m: MasterModel) => void
  setScene: (id: SceneId) => void
  completeSceneTransition: (id: SceneId) => void
  setPlanIndex: (i: number) => void
  toggleFreeze: () => void
  toggleBypass: () => void
  setMixMode: (m: MixMode) => void
  setOverride: (id: number, key: ParamKey, on: boolean) => void
  setLabel: (id: number, cls: SourceClass, lock: boolean) => void
  setName: (id: number, name: string) => void
  select: (id: number | null) => void
  setBrainStatus: (s: 'ok' | 'stalled' | 'error') => void
  pushLog: (kind: LogEntry['kind'], text: string) => void

  // input section / monitoring
  toggleMute: (id: number) => void
  toggleSolo: (id: number) => void
  setChannelField: (id: number, patch: Partial<ChannelModel>) => void
  clearSolo: () => void
  setMonitor: (s: MonitorSource) => void
  setClip: (id: number, clip: boolean) => void
  setMasterMeters: (correlation: number, clip: boolean) => void

  // groups
  setDcaLevel: (group: number, db: number) => void
  toggleMuteGroup: (group: number) => void

  // matrix
  setMatrixMeter: (id: string, lufs: number) => void
  setMixMinusChannel: (id: number | null) => void

  // fx
  setSend: (id: number, which: 'reverb' | 'delay', db: number) => void

  // snapshot depth
  setRecallScope: (patch: Partial<RecallScope>) => void
  toggleSceneSafe: (id: number) => void
  commit: () => void
  undo: () => void
  redo: () => void

  // niceties
  setOscillator: (patch: Partial<OscillatorConfig>) => void
  copyChannel: (id: number) => void
  pasteChannel: (id: number) => void

  // recording
  setRecording: (on: boolean, sessionId?: string | null) => void
  setRecElapsed: (s: number) => void
  setRecordingSessions: (sessions: BrowserRecordingSession[]) => void
  selectRecordingSession: (id: string | null) => void
  setRecordingLibraryStatus: (status: string, error?: string | null) => void
  toggleRecordingSessions: (on?: boolean) => void

  // patch
  setInputs: (i: MixerState['inputs']) => void
  setPatchMap: (p: Record<number, number | null>) => void
  setChannelPatch: (channelId: number, inputId: number | null) => void
  togglePatch: (on?: boolean) => void

  // Planning Center
  setPco: (patch: Partial<Pick<MixerState, 'pcoStatus' | 'pcoPlanTitle' | 'pcoError'>>) => void
  setLivePlan: (items: PlanItem[] | null) => void

  // devices
  setDevices: (d: MixerState['devices']) => void
  setInputDeviceId: (id: string | null) => void
  setOutputDeviceId: (id: string | null) => void
  toggleDevices: (on?: boolean) => void

  reset: () => void
}

const emptyMaster: MasterModel = {
  momentaryLufs: -100, shortLufs: -100, integratedLufs: -100, truePeakDb: -100,
  limiterInputTruePeakDb: -100, masterTrimDb: 0, limiterGrDb: 0,
  targetLufs: -14, ceilingDb: -1, glueGrDb: 0, correlation: 1, clip: false,
}

const initialMatrix: MatrixOut[] = [
  { id: 'stream', name: 'Stream', blurb: 'Main livestream feed', targetLufs: -14, momentaryLufs: -100 },
  { id: 'record', name: 'Record', blurb: 'Archive / podcast', targetLufs: -16, momentaryLufs: -100 },
  { id: 'assist', name: 'Hearing Assist', blurb: 'Speech-forward mono', targetLufs: -18, momentaryLufs: -100 },
  { id: 'mixminus', name: 'Mix-Minus', blurb: 'Program minus the remote guest', targetLufs: -16, momentaryLufs: -100 },
]

const initialDca: DcaGroup[] = [
  { id: 1, name: 'Band', levelDb: 0 },
  { id: 2, name: 'Vocals', levelDb: 0 },
  { id: 3, name: 'Speech', levelDb: 0 },
]

function snap(s: MixerState): UndoSnap {
  return {
    channels: s.channels.map((c) => ({ ...c, overrides: { ...c.overrides } })),
    sceneId: s.sceneId,
    dcaGroups: s.dcaGroups.map((d) => ({ ...d })),
    recallScope: { ...s.recallScope },
  }
}

const undoStack: UndoSnap[] = []
const redoStack: UndoSnap[] = []

function transitionTo(from: SceneId, to: SceneId): SceneTransition | null {
  if (from === to) return null
  return { from, to, startedAtMs: Date.now() }
}

export const useStore = create<MixerState>((set, get) => ({
  started: false,
  mode: 'synthetic',
  channels: [],
  master: emptyMaster,
  sceneId: 'preservice',
  sceneTransition: null,
  planIndex: 0,
  mixMode: 'soundcheck',
  frozen: false,
  bypassed: false,
  brainStatus: 'ok',
  selectedChannel: null,
  log: [],

  monitorSource: 'program',
  dcaGroups: initialDca,
  muteGroups: [false, false, false, false],
  matrix: initialMatrix,
  mixMinusChannelId: null,
  recallScope: { levels: true, eq: true, dynamics: true, routing: true },
  oscillator: { on: false, type: 'tone', dest: 'master', levelDb: -20 },
  recording: false,
  recElapsed: 0,
  recordingSessions: [],
  activeRecordingSessionId: null,
  selectedRecordingSessionId: null,
  recordingLibraryStatus: 'Loading sessions…',
  recordingError: null,
  showRecordingSessions: false,
  clipboard: null,
  undoDepth: 0,
  redoDepth: 0,
  inputs: [],
  patch: {},
  showPatch: false,
  pcoStatus: 'idle',
  pcoPlanTitle: null,
  pcoError: null,
  livePlan: null,
  devices: { inputs: [], outputs: [], canSetSink: false },
  inputDeviceId: null,
  outputDeviceId: null,
  showDevices: false,

  setStarted: (b, mode) => set({ started: b, mode }),
  initChannels: (c) => set({ channels: c }),
  setChannels: (c) => set({ channels: c }),
  patchChannel: (id, patch) =>
    set((s) => ({ channels: s.channels.map((ch) => (ch.id === id ? { ...ch, ...patch } : ch)) })),
  setMaster: (m) => set({ master: m }),
  setScene: (id) =>
    set((s) => {
      if (s.sceneId === id) return {}
      return {
        sceneId: id,
        sceneTransition: transitionTo(s.sceneId, id),
      }
    }),
  completeSceneTransition: (id) =>
    set((s) => (
      s.sceneTransition?.to === id
        ? { sceneTransition: null }
        : {}
    )),
  setPlanIndex: (i) => set({ planIndex: i }),
  toggleFreeze: () => set((s) => ({ frozen: !s.frozen })),
  toggleBypass: () => set((s) => ({ bypassed: !s.bypassed })),
  setMixMode: (m) => set({ mixMode: m }),
  setOverride: (id, key, on) =>
    set((s) => ({
      channels: s.channels.map((ch) =>
        ch.id === id ? { ...ch, overrides: { ...ch.overrides, [key]: on } } : ch,
      ),
    })),
  setLabel: (id, cls, lock) =>
    set((s) => ({
      channels: s.channels.map((ch) =>
        ch.id === id ? { ...ch, cls, labelLocked: lock, confidence: lock ? 1 : ch.confidence } : ch,
      ),
    })),
  setName: (id, name) =>
    set((s) => ({ channels: s.channels.map((ch) => (ch.id === id ? { ...ch, name } : ch)) })),
  select: (id) => set({ selectedChannel: id }),
  setBrainStatus: (s2) => set({ brainStatus: s2 }),
  pushLog: (kind, text) =>
    set((s) => ({ log: [{ id: ++logId, t: Date.now(), kind, text }, ...s.log].slice(0, 80) })),

  toggleMute: (id) =>
    set((s) => ({ channels: s.channels.map((ch) => (ch.id === id ? { ...ch, muted: !ch.muted } : ch)) })),
  toggleSolo: (id) =>
    set((s) => {
      const ch = s.channels.find((c) => c.id === id)
      const soloing = ch ? !ch.soloed : false
      const channels = s.channels.map((c) => (c.id === id ? { ...c, soloed: soloing } : c))
      const anySolo = channels.some((c) => c.soloed)
      return { channels, monitorSource: anySolo ? 'solo' : (s.monitorSource === 'solo' ? 'program' : s.monitorSource) }
    }),
  clearSolo: () =>
    set((s) => ({
      channels: s.channels.map((c) => ({ ...c, soloed: false })),
      monitorSource: s.monitorSource === 'solo' ? 'program' : s.monitorSource,
    })),
  setChannelField: (id, patch) =>
    set((s) => ({ channels: s.channels.map((ch) => (ch.id === id ? { ...ch, ...patch } : ch)) })),
  setMonitor: (src) => set({ monitorSource: src }),
  setClip: (id, clip) =>
    set((s) => ({ channels: s.channels.map((ch) => (ch.id === id ? { ...ch, clip } : ch)) })),
  setMasterMeters: (correlation, clip) =>
    set((s) => ({ master: { ...s.master, correlation, clip } })),

  setDcaLevel: (group, db) =>
    set((s) => ({ dcaGroups: s.dcaGroups.map((d) => (d.id === group ? { ...d, levelDb: db } : d)) })),
  toggleMuteGroup: (group) =>
    set((s) => ({ muteGroups: s.muteGroups.map((m, i) => (i === group ? !m : m)) })),

  setMatrixMeter: (id, lufs) =>
    set((s) => ({ matrix: s.matrix.map((m) => (m.id === id ? { ...m, momentaryLufs: lufs } : m)) })),
  setMixMinusChannel: (id) => set({ mixMinusChannelId: id }),

  setSend: (id, which, db) =>
    set((s) => ({
      channels: s.channels.map((ch) =>
        ch.id === id ? { ...ch, [which === 'reverb' ? 'reverbSendDb' : 'delaySendDb']: db } : ch,
      ),
    })),

  setRecallScope: (patch) => set((s) => ({ recallScope: { ...s.recallScope, ...patch } })),
  toggleSceneSafe: (id) =>
    set((s) => ({ channels: s.channels.map((ch) => (ch.id === id ? { ...ch, sceneSafe: !ch.sceneSafe } : ch)) })),
  commit: () => {
    undoStack.push(snap(get()))
    if (undoStack.length > 50) undoStack.shift()
    redoStack.length = 0
    set({ undoDepth: undoStack.length, redoDepth: 0 })
  },
  undo: () => {
    const prev = undoStack.pop()
    if (!prev) return
    redoStack.push(snap(get()))
    const currentScene = get().sceneId
    set({
      channels: prev.channels, sceneId: prev.sceneId, dcaGroups: prev.dcaGroups,
      recallScope: prev.recallScope, undoDepth: undoStack.length, redoDepth: redoStack.length,
      sceneTransition: transitionTo(currentScene, prev.sceneId),
    })
  },
  redo: () => {
    const next = redoStack.pop()
    if (!next) return
    undoStack.push(snap(get()))
    const currentScene = get().sceneId
    set({
      channels: next.channels, sceneId: next.sceneId, dcaGroups: next.dcaGroups,
      recallScope: next.recallScope, undoDepth: undoStack.length, redoDepth: redoStack.length,
      sceneTransition: transitionTo(currentScene, next.sceneId),
    })
  },

  setOscillator: (patch) => set((s) => ({ oscillator: { ...s.oscillator, ...patch } })),
  copyChannel: (id) =>
    set((s) => {
      const ch = s.channels.find((c) => c.id === id)
      if (!ch) return {}
      const { polarityInv, inputDelayMs, dca, muteGroup, reverbSendDb, delaySendDb, pan, overrides } = ch
      return { clipboard: { polarityInv, inputDelayMs, dca, muteGroup, reverbSendDb, delaySendDb, pan, overrides: { ...overrides } } }
    }),
  pasteChannel: (id) =>
    set((s) => {
      if (!s.clipboard) return {}
      return { channels: s.channels.map((ch) => (ch.id === id ? { ...ch, ...s.clipboard, overrides: { ...s.clipboard!.overrides } } : ch)) }
    }),

  setRecording: (on, sessionId) => set((s) => ({
    recording: on,
    activeRecordingSessionId: sessionId === undefined ? s.activeRecordingSessionId : sessionId,
    selectedRecordingSessionId: on && sessionId ? sessionId : s.selectedRecordingSessionId,
    recElapsed: on ? 0 : s.recElapsed,
  })),
  setRecElapsed: (sec) => set({ recElapsed: sec }),
  setRecordingSessions: (sessions) => set((s) => ({
    recordingSessions: sessions,
    selectedRecordingSessionId: s.selectedRecordingSessionId && sessions.some((session) => session.id === s.selectedRecordingSessionId)
      ? s.selectedRecordingSessionId
      : sessions[0]?.id ?? null,
  })),
  selectRecordingSession: (id) => set({ selectedRecordingSessionId: id }),
  setRecordingLibraryStatus: (status, error = null) => set({ recordingLibraryStatus: status, recordingError: error }),
  toggleRecordingSessions: (on) => set((s) => ({ showRecordingSessions: on === undefined ? !s.showRecordingSessions : on })),

  setInputs: (inputs) => set({ inputs }),
  setPatchMap: (patch) => set({ patch }),
  setChannelPatch: (channelId, inputId) => set((s) => ({ patch: { ...s.patch, [channelId]: inputId } })),
  togglePatch: (on) => set((s) => ({ showPatch: on === undefined ? !s.showPatch : on })),

  setPco: (patch) => set(patch),
  setLivePlan: (items) => set({ livePlan: items }),

  setDevices: (devices) => set({ devices }),
  setInputDeviceId: (id) => set({ inputDeviceId: id }),
  setOutputDeviceId: (id) => set({ outputDeviceId: id }),
  toggleDevices: (on) => set((s) => ({ showDevices: on === undefined ? !s.showDevices : on })),

  reset: () => {
    undoStack.length = 0; redoStack.length = 0
    set({
      started: false, channels: [], master: emptyMaster, log: [], planIndex: 0,
      sceneId: 'preservice', sceneTransition: null,
      monitorSource: 'program', muteGroups: [false, false, false, false], dcaGroups: initialDca,
      matrix: initialMatrix, mixMinusChannelId: null, recording: false, activeRecordingSessionId: null,
      oscillator: { on: false, type: 'tone', dest: 'master', levelDb: -20 }, undoDepth: 0, redoDepth: 0,
      inputs: [], patch: {}, showPatch: false,
      pcoStatus: 'idle', pcoPlanTitle: null, pcoError: null, livePlan: null,
      devices: { inputs: [], outputs: [], canSetSink: false }, inputDeviceId: null, outputDeviceId: null, showDevices: false,
    })
  },
}))
