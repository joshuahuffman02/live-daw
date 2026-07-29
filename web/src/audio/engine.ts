// The audio engine: builds the Web Audio graph that mirrors the spec's signal flow,
// now with full-console routing: input section (polarity / delay / mute), PFL solo
// bus with a monitor switch (so soloing never disturbs the program/stream), DCA
// gains, two FX buses (reverb + delay throwback), a mix-minus (N-1) bus and matrix
// outputs (stream / record / hearing-assist), program correlation metering, master
// recording, and a calibration oscillator.
//
// The program (stream) path is always computed and metered independently of what the
// operator is auditioning. NO ML anywhere in this file.

import type { BusId, MonitorSource, SourceClass } from '../types'
import { STAGE, SPEECH_CHANNEL_IDS, type StageChannelDef } from './stage'
import { dbToGain } from './util'

export type InputMode = 'synthetic' | 'mic' | 'file'

// a physical input (a Dante flow in the appliance; a synth stand-in here)
export interface InputSource {
  id: number
  name: string // Dante transmitter channel name
  node: AudioNode
  defaultClass: SourceClass
  stereo: boolean
  stop?: () => void
}

export interface ChannelNodes {
  id: number
  def: StageChannelDef
  patchedInputId: number | null
  patchedClass: SourceClass
  preAnalyser: AnalyserNode
  postAnalyser: AnalyserNode
  polarity: GainNode
  inputDelay: DelayNode
  trim: GainNode
  hpf: BiquadFilterNode
  gate: AudioWorkletNode
  corr: [BiquadFilterNode, BiquadFilterNode]
  mask: [BiquadFilterNode, BiquadFilterNode]
  comp: DynamicsCompressorNode
  voice: [BiquadFilterNode, BiquadFilterNode, BiquadFilterNode]
  deEss: BiquadFilterNode
  fader: GainNode
  dcaGain: GainNode
  mute: GainNode
  soloSend: GainNode
  panner: StereoPannerNode | null
  reverbSend: GainNode
  delaySend: GainNode
  mixMinusSend: GainNode
  safeGain: GainNode
  isStereo: boolean
  isSpeech: boolean
  automixIndex: number
  gateOpen: boolean
  gateGrDb: number
  automixGainDb: number
}

export interface MasterTelemetry {
  momentary: number
  short: number
  integrated: number
  truePeak: number
  inputTruePeak: number
  grDb: number
  target: number
  ceiling: number
}

export class AudioEngine {
  ctx!: AudioContext
  mode: InputMode = 'synthetic'
  inputs: InputSource[] = []
  channels: ChannelNodes[] = []
  buses: Record<BusId, GainNode> = {} as any
  masterInput!: GainNode
  glue!: DynamicsCompressorNode
  masterEq: BiquadFilterNode[] = []
  masterTrim!: GainNode
  masterProcessed!: GainNode
  safeBus!: GainNode
  safeMaster!: GainNode
  limiterInput!: GainNode
  loudness!: AudioWorkletNode
  programMaster!: GainNode
  automix!: AudioWorkletNode

  // FX
  reverbBus!: GainNode
  convolver!: ConvolverNode
  reverbReturn!: GainNode
  delayBus!: GainNode
  delayNode!: DelayNode
  delayFb!: GainNode
  delayReturn!: GainNode

  // monitoring + matrix
  soloBus!: GainNode
  assistBus!: GainNode
  mixMinusBus!: GainNode
  programMon!: GainNode
  soloMon!: GainNode
  assistMon!: GainNode
  mmMon!: GainNode
  corrL!: AnalyserNode
  corrR!: AnalyserNode
  recAnalyser!: AnalyserNode
  assistAnalyser!: AnalyserNode
  mmAnalyser!: AnalyserNode

  // recording + oscillator
  recDest!: MediaStreamAudioDestinationNode
  private recorder: MediaRecorder | null = null
  private recChunks: BlobPart[] = []
  private osc: OscillatorNode | AudioBufferSourceNode | null = null
  private oscGain!: GainNode

  loudnessTel: MasterTelemetry = {
    momentary: -100, short: -100, integrated: -100, truePeak: -100,
    inputTruePeak: -100, grDb: 0, target: -14, ceiling: -1,
  }
  bypassed = false
  private speechIds: number[] = []
  private started = false
  private corrBufL = new Float32Array(1024)
  private corrBufR = new Float32Array(1024)
  private rmsBuf = new Float32Array(1024)

  async init() {
    this.ctx = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' })
    const base = import.meta.env.BASE_URL || '/'
    await Promise.all([
      this.ctx.audioWorklet.addModule(`${base}worklets/automix-processor.js`),
      this.ctx.audioWorklet.addModule(`${base}worklets/loudness-processor.js`),
      this.ctx.audioWorklet.addModule(`${base}worklets/gate-processor.js`),
      this.ctx.audioWorklet.addModule(`${base}worklets/stage-source-processor.js`),
    ])
  }

  private makeIR(seconds = 1.8, decay = 3.2): AudioBuffer {
    const sr = this.ctx.sampleRate
    const len = Math.floor(seconds * sr)
    const buf = this.ctx.createBuffer(2, len, sr)
    for (let c = 0; c < 2; c++) {
      const d = buf.getChannelData(c)
      for (let i = 0; i < len; i++) {
        const env = Math.pow(1 - i / len, decay)
        d[i] = (Math.random() * 2 - 1) * env
      }
      for (let i = 1; i < len; i++) d[i] = 0.7 * d[i] + 0.3 * d[i - 1]
    }
    return buf
  }

  private buildMaster() {
    const ctx = this.ctx

    // monitor mixing -> destination (program / solo / matrix audition)
    this.programMon = ctx.createGain(); this.programMon.gain.value = 1
    this.soloMon = ctx.createGain(); this.soloMon.gain.value = 0
    this.assistMon = ctx.createGain(); this.assistMon.gain.value = 0
    this.mmMon = ctx.createGain(); this.mmMon.gain.value = 0
    for (const g of [this.programMon, this.soloMon, this.assistMon, this.mmMon]) g.connect(ctx.destination)

    // loudness/limiter on the program path (always meters the stream)
    this.loudness = new AudioWorkletNode(ctx, 'loudness-processor', {
      numberOfInputs: 1, numberOfOutputs: 1,
      outputChannelCount: [2], channelCount: 2, channelCountMode: 'explicit',
    })
    this.loudness.port.onmessage = (e) => {
      const d = e.data
      if (d && d.type === 'loudness') {
        this.loudnessTel = {
          momentary: d.momentary, short: d.short, integrated: d.integrated,
          truePeak: d.truePeak, inputTruePeak: d.inputTruePeak,
          grDb: d.grDb, target: d.target, ceiling: d.ceiling,
        }
      }
    }
    this.programMaster = ctx.createGain(); this.programMaster.gain.value = 1
    this.loudness.connect(this.programMaster)
    this.programMaster.connect(this.programMon)

    // recording tap + correlation taps on the program master
    this.recDest = ctx.createMediaStreamDestination()
    this.programMaster.connect(this.recDest)
    const split = ctx.createChannelSplitter(2)
    this.programMaster.connect(split)
    this.corrL = ctx.createAnalyser(); this.corrL.fftSize = 1024
    this.corrR = ctx.createAnalyser(); this.corrR.fftSize = 1024
    split.connect(this.corrL, 0)
    split.connect(this.corrR, 1)
    this.recAnalyser = ctx.createAnalyser(); this.recAnalyser.fftSize = 1024
    this.programMaster.connect(this.recAnalyser)

    this.limiterInput = ctx.createGain()
    this.limiterInput.connect(this.loudness)

    // processed master path
    this.masterInput = ctx.createGain()
    this.glue = ctx.createDynamicsCompressor()
    this.glue.threshold.value = -18; this.glue.ratio.value = 2
    this.glue.attack.value = 0.03; this.glue.release.value = 0.25; this.glue.knee.value = 8
    const eqLow = ctx.createBiquadFilter(); eqLow.type = 'lowshelf'; eqLow.frequency.value = 120; eqLow.gain.value = 0
    const eqPres = ctx.createBiquadFilter(); eqPres.type = 'peaking'; eqPres.frequency.value = 3000; eqPres.Q.value = 0.8; eqPres.gain.value = 0.5
    const eqAir = ctx.createBiquadFilter(); eqAir.type = 'highshelf'; eqAir.frequency.value = 12000; eqAir.gain.value = 1
    this.masterEq = [eqLow, eqPres, eqAir]
    this.masterTrim = ctx.createGain(); this.masterTrim.gain.value = 1
    this.masterProcessed = ctx.createGain(); this.masterProcessed.gain.value = 1
    this.masterInput.connect(this.glue)
    this.glue.connect(eqLow); eqLow.connect(eqPres); eqPres.connect(eqAir)
    eqAir.connect(this.masterTrim)
    this.masterTrim.connect(this.masterProcessed)
    this.masterProcessed.connect(this.limiterInput)

    // SAFE bypass path
    this.safeBus = ctx.createGain(); this.safeBus.gain.value = 0.5
    this.safeMaster = ctx.createGain(); this.safeMaster.gain.value = 0
    this.safeBus.connect(this.safeMaster)
    this.safeMaster.connect(this.limiterInput)

    // subgroups
    for (const id of ['drums', 'band', 'vocals', 'speech'] as BusId[]) {
      const g = ctx.createGain(); g.gain.value = 1
      g.connect(this.masterInput)
      this.buses[id] = g
    }
    this.buses.master = this.masterInput

    // reverb FX bus
    this.reverbBus = ctx.createGain(); this.reverbBus.gain.value = 1
    this.convolver = ctx.createConvolver(); this.convolver.buffer = this.makeIR()
    this.reverbReturn = ctx.createGain(); this.reverbReturn.gain.value = dbToGain(-12)
    this.reverbBus.connect(this.convolver); this.convolver.connect(this.reverbReturn)
    this.reverbReturn.connect(this.masterInput)

    // delay FX bus (throwback)
    this.delayBus = ctx.createGain(); this.delayBus.gain.value = 1
    this.delayNode = ctx.createDelay(1.0); this.delayNode.delayTime.value = 0.38
    this.delayFb = ctx.createGain(); this.delayFb.gain.value = 0.34
    this.delayReturn = ctx.createGain(); this.delayReturn.gain.value = dbToGain(-12)
    this.delayBus.connect(this.delayNode)
    this.delayNode.connect(this.delayFb); this.delayFb.connect(this.delayNode)
    this.delayNode.connect(this.delayReturn); this.delayReturn.connect(this.masterInput)

    // hearing-assist bus: speech full + music low, mono-ish
    this.assistBus = ctx.createGain(); this.assistBus.gain.value = 1
    this.assistBus.connect(this.assistMon)
    this.assistAnalyser = ctx.createAnalyser(); this.assistAnalyser.fftSize = 1024
    this.assistBus.connect(this.assistAnalyser)
    const speechToAssist = ctx.createGain(); speechToAssist.gain.value = 1
    this.buses.speech.connect(speechToAssist); speechToAssist.connect(this.assistBus)
    for (const id of ['band', 'vocals', 'drums'] as BusId[]) {
      const g = ctx.createGain(); g.gain.value = dbToGain(-12)
      this.buses[id].connect(g); g.connect(this.assistBus)
    }

    // mix-minus (N-1) bus — fed per channel via mixMinusSend
    this.mixMinusBus = ctx.createGain(); this.mixMinusBus.gain.value = 1
    this.mixMinusBus.connect(this.mmMon)
    this.mmAnalyser = ctx.createAnalyser(); this.mmAnalyser.fftSize = 1024
    this.mixMinusBus.connect(this.mmAnalyser)

    // solo (PFL) bus
    this.soloBus = ctx.createGain(); this.soloBus.gain.value = 1
    this.soloBus.connect(this.soloMon)

    // calibration oscillator (off by default)
    this.oscGain = ctx.createGain(); this.oscGain.gain.value = 0
    this.oscGain.connect(this.masterInput)
  }

  private makeBiquad(type: BiquadFilterType, freq: number, q: number, gain: number) {
    const f = this.ctx.createBiquadFilter()
    f.type = type; f.frequency.value = freq; f.Q.value = q; f.gain.value = gain
    return f
  }

  private buildChannel(def: StageChannelDef, automixIndex: number, isSpeech: boolean): ChannelNodes {
    const ctx = this.ctx
    const preAnalyser = ctx.createAnalyser(); preAnalyser.fftSize = 2048; preAnalyser.smoothingTimeConstant = 0.6
    const postAnalyser = ctx.createAnalyser(); postAnalyser.fftSize = 1024; postAnalyser.smoothingTimeConstant = 0.5

    const polarity = ctx.createGain(); polarity.gain.value = 1
    const inputDelay = ctx.createDelay(0.1); inputDelay.delayTime.value = 0
    const trim = ctx.createGain(); trim.gain.value = 1
    const hpf = this.makeBiquad('highpass', 80, 0.707, 0)
    const gate = new AudioWorkletNode(ctx, 'gate-processor', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1] })
    const corr: [BiquadFilterNode, BiquadFilterNode] = [this.makeBiquad('peaking', 500, 4, 0), this.makeBiquad('peaking', 2000, 4, 0)]
    const mask: [BiquadFilterNode, BiquadFilterNode] = [this.makeBiquad('peaking', 330, 1.5, 0), this.makeBiquad('peaking', 3000, 1.3, 0)]
    const comp = ctx.createDynamicsCompressor()
    comp.threshold.value = -24; comp.ratio.value = 2.5; comp.attack.value = 0.01; comp.release.value = 0.2; comp.knee.value = 8
    const voice: [BiquadFilterNode, BiquadFilterNode, BiquadFilterNode] = [
      this.makeBiquad('peaking', 300, 1, 0), this.makeBiquad('peaking', 3000, 1, 0), this.makeBiquad('highshelf', 10000, 0.7, 0),
    ]
    const deEss = this.makeBiquad('highshelf', 7000, 0.8, 0)
    const fader = ctx.createGain(); fader.gain.value = dbToGain(-6)
    const dcaGain = ctx.createGain(); dcaGain.gain.value = 1
    const mute = ctx.createGain(); mute.gain.value = 1
    const soloSend = ctx.createGain(); soloSend.gain.value = 0
    const reverbSend = ctx.createGain(); reverbSend.gain.value = 0
    const delaySend = ctx.createGain(); delaySend.gain.value = 0
    const mixMinusSend = ctx.createGain(); mixMinusSend.gain.value = 1
    const safeGain = ctx.createGain(); safeGain.gain.value = dbToGain(-8)

    // input section — `polarity` is the channel's input node; a patched InputSource
    // connects into it via patch(). The pre-analyser / safe tap follow the patch.
    polarity.connect(inputDelay)
    inputDelay.connect(preAnalyser)
    inputDelay.connect(safeGain); safeGain.connect(this.safeBus)

    // processing chain
    inputDelay.connect(trim)
    trim.connect(hpf); hpf.connect(gate)
    gate.connect(corr[0]); corr[0].connect(corr[1])
    corr[1].connect(mask[0]); mask[0].connect(mask[1]); mask[1].connect(comp)
    comp.connect(voice[0]); voice[0].connect(voice[1]); voice[1].connect(voice[2]); voice[2].connect(deEss)
    // PFL solo tap (pre-fader, ignores mute) — audition the AI's processing
    deEss.connect(soloSend); soloSend.connect(this.soloBus)
    deEss.connect(fader)
    fader.connect(dcaGain); dcaGain.connect(mute)
    mute.connect(postAnalyser)
    // FX + mix-minus sends (post-mute)
    mute.connect(reverbSend); reverbSend.connect(this.reverbBus)
    mute.connect(delaySend); delaySend.connect(this.delayBus)
    mute.connect(mixMinusSend); mixMinusSend.connect(this.mixMinusBus)

    let panner: StereoPannerNode | null = null
    if (isSpeech) {
      mute.connect(this.automix, 0, automixIndex)
    } else {
      panner = ctx.createStereoPanner(); panner.pan.value = 0
      mute.connect(panner)
      panner.connect(this.buses.band)
    }

    const ch: ChannelNodes = {
      id: def.id, def, patchedInputId: null, patchedClass: 'unknown',
      preAnalyser, postAnalyser, polarity, inputDelay, trim, hpf, gate, corr, mask, comp,
      voice, deEss, fader, dcaGain, mute, soloSend, panner, reverbSend, delaySend, mixMinusSend, safeGain,
      isStereo: false, isSpeech, automixIndex, gateOpen: false, gateGrDb: 0, automixGainDb: isSpeech ? 0 : -60,
    }
    gate.port.onmessage = (e) => {
      const d = e.data
      if (d && d.type === 'state') { ch.gateOpen = d.open; ch.gateGrDb = d.gainDb }
    }
    return ch
  }

  routeToBus(ch: ChannelNodes, bus: BusId) {
    if (ch.isSpeech || !ch.panner) return
    try { ch.panner.disconnect() } catch {}
    const target = this.buses[bus] || this.buses.band
    ch.panner.connect(target)
  }

  private makeSyntheticSource(def: StageChannelDef): AudioNode {
    if (def.kind === 'tracks') {
      // stereo source: two detuned pads merged L/R
      const merger = this.ctx.createChannelMerger(2)
      const l = new AudioWorkletNode(this.ctx, 'stage-source-processor', { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [1], processorOptions: { kind: 'keys', seed: def.id, level: def.level } })
      const r = new AudioWorkletNode(this.ctx, 'stage-source-processor', { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [1], processorOptions: { kind: 'keys', seed: def.id + 7, level: def.level } })
      l.connect(merger, 0, 0); r.connect(merger, 0, 1)
      return merger
    }
    return new AudioWorkletNode(this.ctx, 'stage-source-processor', {
      numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [1],
      processorOptions: { kind: def.kind, seed: def.id, level: def.level },
    })
  }

  private buildAutomix(count: number) {
    this.automix = new AudioWorkletNode(this.ctx, 'automix-processor', {
      numberOfInputs: count, numberOfOutputs: 1, outputChannelCount: [1],
      processorOptions: { channels: count },
    })
    this.automix.connect(this.buses.speech)
    this.automix.port.onmessage = (e) => {
      const d = e.data
      if (d && d.type === 'gains') {
        this.speechIds.forEach((id, i) => {
          const ch = this.channels.find((c) => c.id === id)
          if (ch) ch.automixGainDb = d.gains[i] > 1e-4 ? 20 * Math.log10(d.gains[i]) : -60
        })
      }
    }
  }

  private makeInput(def: StageChannelDef): InputSource {
    return { id: def.id, name: def.label, node: this.makeSyntheticSource(def), defaultClass: def.trueClass, stereo: def.kind === 'tracks' }
  }

  // The PATCH: connect an input source to a channel's input node. inputId null =
  // unpatched. One input may feed several channels (split); unpatching one leaves the
  // others. This is the layer that handles repatches, guests, "a laptop on ch 14".
  patch(channelId: number, inputId: number | null) {
    const ch = this.channels.find((c) => c.id === channelId)
    if (!ch) return
    if (ch.patchedInputId !== null) {
      const old = this.inputs.find((i) => i.id === ch.patchedInputId)
      if (old) { try { old.node.disconnect(ch.polarity) } catch {} }
    }
    ch.patchedInputId = inputId
    if (inputId !== null) {
      const inp = this.inputs.find((i) => i.id === inputId)
      if (inp) { try { inp.node.connect(ch.polarity) } catch {}; ch.patchedClass = inp.defaultClass; ch.isStereo = inp.stereo }
    } else {
      ch.patchedClass = 'unknown'; ch.isStereo = false
    }
  }

  inputInfos() {
    return this.inputs.map((i) => ({ id: i.id, name: i.name, defaultClass: i.defaultClass, stereo: i.stereo }))
  }
  patchedInput(ch: ChannelNodes): InputSource | undefined {
    return ch.patchedInputId === null ? undefined : this.inputs.find((i) => i.id === ch.patchedInputId)
  }

  async buildSynthetic() {
    this.mode = 'synthetic'
    this.speechIds = SPEECH_CHANNEL_IDS
    this.buildMaster()
    this.buildAutomix(this.speechIds.length)
    this.inputs = STAGE.map((def) => this.makeInput(def))
    this.channels = STAGE.map((def) => {
      const isSpeech = this.speechIds.includes(def.id)
      const idx = isSpeech ? this.speechIds.indexOf(def.id) : -1
      return this.buildChannel(def, idx, isSpeech)
    })
    this.channels.forEach((ch) => this.patch(ch.id, ch.id)) // default 1:1
  }

  async buildMic(deviceId?: string) {
    this.mode = 'mic'
    this.speechIds = [101]
    this.buildMaster()
    this.buildAutomix(1)
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { deviceId: deviceId ? { exact: deviceId } : undefined, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
    })
    const node = this.ctx.createMediaStreamSource(stream)
    this.inputs = [{ id: 101, name: 'Live Mic', node, defaultClass: 'speech', stereo: false, stop: () => stream.getTracks().forEach((t) => t.stop()) }]
    const def: StageChannelDef = { id: 101, name: 'Live Mic', label: 'Live Mic', kind: 'speech', trueClass: 'speech', level: 1 }
    this.channels = [this.buildChannel(def, 0, true)]
    this.patch(101, 101)
  }

  // ---- device selection ----
  async listDevices(): Promise<{ inputs: { deviceId: string; label: string }[]; outputs: { deviceId: string; label: string }[]; canSetSink: boolean }> {
    let ds: MediaDeviceInfo[] = []
    try { ds = await navigator.mediaDevices.enumerateDevices() } catch {}
    const map = (k: MediaDeviceKind, fallback: string) =>
      ds.filter((d) => d.kind === k).map((d, i) => ({ deviceId: d.deviceId, label: d.label || `${fallback} ${i + 1}` }))
    return {
      inputs: map('audioinput', 'Microphone'),
      outputs: map('audiooutput', 'Output'),
      canSetSink: typeof (this.ctx as any).setSinkId === 'function',
    }
  }

  micDeviceId(): string | null {
    const ms = (this.inputs[0]?.node as any)?.mediaStream as MediaStream | undefined
    return ms ? ms.getAudioTracks()[0]?.getSettings().deviceId ?? null : null
  }

  async setOutputDevice(deviceId: string) {
    const ctx = this.ctx as any
    if (typeof ctx.setSinkId === 'function') { try { await ctx.setSinkId(deviceId) } catch {} }
  }

  // swap the live mic to a specific input device, re-patching it into its channel(s)
  async setMicInput(deviceId: string) {
    if (this.mode !== 'mic') return
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { deviceId: deviceId ? { exact: deviceId } : undefined, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
    })
    const node = this.ctx.createMediaStreamSource(stream)
    const old = this.inputs.find((i) => i.id === 101)
    const using = this.channels.filter((c) => c.patchedInputId === 101)
    if (old) { try { old.node.disconnect() } catch {}; old.stop && old.stop() }
    this.inputs = this.inputs.map((i) => (i.id === 101 ? { ...i, node, stop: () => stream.getTracks().forEach((t) => t.stop()) } : i))
    using.forEach((c) => { try { node.connect(c.polarity) } catch {} })
  }

  setBypass(on: boolean) {
    this.bypassed = on
    const ctx = this.ctx
    this.masterProcessed.gain.setTargetAtTime(on ? 0 : 1, ctx.currentTime, 0.05)
    this.safeMaster.gain.setTargetAtTime(on ? 1 : 0, ctx.currentTime, 0.05)
  }

  setMonitor(src: MonitorSource) {
    const t = this.ctx.currentTime
    const set = (g: GainNode, v: number) => g.gain.setTargetAtTime(v, t, 0.03)
    // record/stream audition the program audio itself
    const program = src === 'program' || src === 'record' || src === 'stream'
    set(this.programMon, program ? 1 : 0)
    set(this.soloMon, src === 'solo' ? 1 : 0)
    set(this.assistMon, src === 'assist' ? 1 : 0)
    set(this.mmMon, src === 'mixminus' ? 1 : 0)
  }

  setOscillator(on: boolean, type: 'tone' | 'pink', dest: 'master' | number, levelDb: number) {
    // tear down existing
    if (this.osc) { try { this.osc.stop() } catch {} try { this.osc.disconnect() } catch {}; this.osc = null }
    try { this.oscGain.disconnect() } catch {}
    if (!on) { this.oscGain.gain.value = 0; return }
    const ctx = this.ctx
    if (type === 'tone') {
      const o = ctx.createOscillator(); o.type = 'sine'; o.frequency.value = 1000; o.start(); this.osc = o
    } else {
      const len = ctx.sampleRate * 2
      const buf = ctx.createBuffer(1, len, ctx.sampleRate)
      const d = buf.getChannelData(0); let last = 0
      for (let i = 0; i < len; i++) { const w = Math.random() * 2 - 1; last = 0.98 * last + 0.02 * w; d[i] = (w + last * 4) * 0.2 }
      const s = ctx.createBufferSource(); s.buffer = buf; s.loop = true; s.start(); this.osc = s
    }
    this.osc.connect(this.oscGain)
    this.oscGain.gain.value = dbToGain(levelDb)
    if (dest === 'master') this.oscGain.connect(this.masterInput)
    else { const ch = this.channels.find((c) => c.id === dest); if (ch) this.oscGain.connect(ch.trim) }
  }

  startRecording() {
    this.recChunks = []
    const mime = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus' : 'audio/webm'
    this.recorder = new MediaRecorder(this.recDest.stream, { mimeType: mime })
    this.recorder.ondataavailable = (e) => { if (e.data.size) this.recChunks.push(e.data) }
    this.recorder.start()
  }
  stopRecording(): Promise<string> {
    return new Promise((resolve) => {
      if (!this.recorder) return resolve('')
      this.recorder.onstop = () => {
        const blob = new Blob(this.recChunks, { type: 'audio/webm' })
        resolve(URL.createObjectURL(blob))
      }
      this.recorder.stop(); this.recorder = null
    })
  }

  // correlation coefficient of the program L/R (-1..+1), for mono compatibility
  readCorrelation(): number {
    this.corrL.getFloatTimeDomainData(this.corrBufL)
    this.corrR.getFloatTimeDomainData(this.corrBufR)
    let sLR = 0, sLL = 0, sRR = 0
    for (let i = 0; i < this.corrBufL.length; i++) {
      const l = this.corrBufL[i], r = this.corrBufR[i]
      sLR += l * r; sLL += l * l; sRR += r * r
    }
    const den = Math.sqrt(sLL * sRR)
    return den > 1e-9 ? Math.max(-1, Math.min(1, sLR / den)) : 1
  }

  // rough momentary level (dBFS, ~ LUFS estimate) of a matrix analyser
  private analyserDb(a: AnalyserNode): number {
    a.getFloatTimeDomainData(this.rmsBuf)
    let s = 0
    for (let i = 0; i < this.rmsBuf.length; i++) s += this.rmsBuf[i] * this.rmsBuf[i]
    const r = Math.sqrt(s / this.rmsBuf.length)
    return r > 1e-6 ? 20 * Math.log10(r) - 0.7 : -100
  }
  readMatrixLevels() {
    return {
      stream: this.loudnessTel.momentary,
      record: this.analyserDb(this.recAnalyser),
      assist: this.analyserDb(this.assistAnalyser),
      mixminus: this.analyserDb(this.mmAnalyser),
    }
  }

  async resume() { if (this.started) return; await this.ctx.resume(); this.started = true }
  glueGrDb(): number { return (this.glue as any).reduction ?? 0 }
  dispose() {
    try { this.recorder && this.recorder.stop() } catch {}
    try { this.inputs.forEach((i) => i.stop && i.stop()) } catch {}
    try { this.ctx.close() } catch {}
  }
}
