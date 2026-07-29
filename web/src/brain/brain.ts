// The "brain": control-rate supervision (~20 Hz) on the main thread. It measures,
// classifies, and sets TARGET parameters that the audio thread ramps to. It never
// processes samples. Manual overrides and FREEZE always win; in live mode its moves
// are rate-limited and confidence-gated; a watchdog drops to the SAFE mix if it stalls.

import type { AudioEngine, ChannelNodes } from '../audio/engine'
import { dbToGain, rmsDb, peakDb, clamp, approach, ramp } from '../audio/util'
import { PROFILES } from './targets'
import { SCENES } from '../scenes/scenes'
import { createClsState, extractFeatures, classify, type ClsState } from './classifier'
import { updateLtas, computeEq, deEssGain } from './autoEq'
import { MASK_BANDS, computeMasking, type MaskInput, type MaskDecision } from './masking'
import type { useStore } from '../store'
import type { BusId, ChannelModel, EqBand, SourceClass } from '../types'

type Store = typeof useStore

interface ChBrain {
  clsState: ClsState
  ltas: Float32Array | null
  freqBuf: Float32Array<ArrayBuffer>
  timeBuf: Float32Array<ArrayBuffer>
  slowPreDb: number
  noiseFloorDb: number
  scores: Partial<Record<SourceClass, number>>
  cls: SourceClass
  candidate: SourceClass
  candCount: number
  confidence: number
  routedBus: BusId | null
  curTrim: number
  curFader: number
  curDeEss: number
  curPan: number
  lastGateThresh: number
  lastGateEnabled: boolean | null
  resonanceHz: number | null
  reason: string
  // cross-channel masking
  effCls: SourceClass
  lastActive: boolean
  bandEnergy: number[]
  maskInfo: { db: number; hz: number; winner: SourceClass | null } | null
  maskKey: string
  clipHold: number
  lastPatchedInputId: number | null
  notchHz: number // held corrective-notch location
  voiceConf: number // settled confidence used to scale voicing (no breathing)
  maskGain: number[] // slewed masking carve per band
  baseBands: EqBand[] // last computed EQ bands (for display, mask bands appended)
}

function bandEnergyOf(ltas: Float32Array, binHz: number): number[] {
  const e = MASK_BANDS.map(() => 0)
  for (let i = 1; i < ltas.length; i++) {
    const f = i * binHz
    const p = Math.pow(10, ltas[i] / 10)
    for (let b = 0; b < MASK_BANDS.length; b++) {
      if (f >= MASK_BANDS[b].lo && f < MASK_BANDS[b].hi) { e[b] += p; break }
    }
  }
  return e
}

const dcaGroup = (bus: BusId): 'band' | 'vocals' | 'speech' =>
  bus === 'vocals' ? 'vocals' : bus === 'speech' ? 'speech' : 'band'

const fmt = (db: number) => (db >= 0 ? '+' : '') + db.toFixed(1)
const fixNeg = (v: number) => (isFinite(v) ? v : -140)

const dcaForBus = (bus: BusId) => (bus === 'vocals' ? 2 : bus === 'speech' ? 3 : 1)
const muteGroupForBus = (bus: BusId) => (bus === 'speech' ? 1 : bus === 'vocals' ? 2 : 3)

export function makeInitialModels(engine: AudioEngine): ChannelModel[] {
  return engine.channels.map((ch) => {
    const cls = ch.patchedClass
    const p = PROFILES[cls]
    return {
      id: ch.id,
      name: engine.patchedInput(ch)?.name ?? ch.def.name,
      cls: 'unknown',
      confidence: 0,
      labelLocked: false,
      bus: p.bus,
      isSpeech: ch.isSpeech,
      polarityInv: false,
      inputDelayMs: 0,
      muted: false,
      soloed: false,
      clip: false,
      dca: dcaForBus(p.bus),
      muteGroup: muteGroupForBus(p.bus),
      sceneSafe: false,
      isStereo: ch.isStereo,
      preRmsDb: -100,
      postRmsDb: -100,
      noiseFloorDb: -60,
      trimDb: 0,
      hpfHz: p.hpfHz,
      gateThreshDb: -45,
      gateOpen: false,
      gateGrDb: 0,
      compThreshDb: p.comp.thresholdDb,
      compRatio: p.comp.ratio,
      compGrDb: 0,
      faderDb: -6,
      pan: 0,
      reverbSendDb: -60,
      delaySendDb: -60,
      deEssDb: 0,
      eqBands: [],
      automixGainDb: ch.isSpeech ? 0 : -60,
      overrides: {},
      reason: 'initializing…',
      active: false,
    }
  })
}

export class Brain {
  private engine: AudioEngine
  private store: Store
  private state = new Map<number, ChBrain>()
  private timer: number | null = null
  private watchdog: number | null = null
  private lastTick = 0
  private errorCount = 0
  private tickCount = 0
  private prevScene: string | null = null
  private prevFrozen = false
  private prevBypass = false
  private prevMonitor = 'program'
  private prevOscKey = ''
  private masterTrimDb = 0

  constructor(engine: AudioEngine, store: Store) {
    this.engine = engine
    this.store = store
    for (const ch of engine.channels) {
      this.state.set(ch.id, {
        clsState: createClsState(),
        ltas: null,
        freqBuf: new Float32Array(ch.preAnalyser.frequencyBinCount),
        timeBuf: new Float32Array(ch.preAnalyser.fftSize),
        slowPreDb: -40,
        noiseFloorDb: -60,
        scores: {},
        cls: 'unknown',
        candidate: 'unknown',
        candCount: 0,
        confidence: 0,
        routedBus: null,
        curTrim: 0,
        curFader: -6,
        curDeEss: 0,
        curPan: 0,
        lastGateThresh: -999,
        lastGateEnabled: null,
        resonanceHz: null,
        reason: 'initializing…',
        effCls: 'unknown',
        lastActive: false,
        bandEnergy: MASK_BANDS.map(() => 0),
        maskInfo: null,
        maskKey: '',
        clipHold: 0,
        lastPatchedInputId: ch.patchedInputId,
        notchHz: 0,
        voiceConf: 0,
        maskGain: MASK_BANDS.map(() => 0),
        baseBands: [],
      })
    }
  }

  start() {
    this.lastTick = Date.now()
    this.timer = window.setInterval(() => this.safeTick(), 50)
    this.watchdog = window.setInterval(() => this.checkWatchdog(), 200)
  }

  stop() {
    if (this.timer) clearInterval(this.timer)
    if (this.watchdog) clearInterval(this.watchdog)
    this.timer = this.watchdog = null
  }

  private checkWatchdog() {
    const age = Date.now() - this.lastTick
    const st = this.store.getState()
    if (!st.started) return
    if (age > 600) {
      if (st.brainStatus !== 'stalled') {
        st.setBrainStatus('stalled')
        st.pushLog('safety', `Brain stalled (${age} ms) — engaged SAFE mix automatically.`)
        this.engine.setBypass(true)
      }
    } else if (st.brainStatus === 'stalled') {
      st.setBrainStatus('ok')
      st.pushLog('safety', 'Brain recovered — released SAFE mix.')
      if (!st.bypassed) this.engine.setBypass(false)
    }
  }

  private safeTick() {
    try {
      this.tick()
      this.lastTick = Date.now()
      this.errorCount = 0
    } catch (e) {
      this.errorCount++
      const st = this.store.getState()
      if (this.errorCount >= 3 && st.brainStatus !== 'error') {
        st.setBrainStatus('error')
        st.pushLog('safety', `Brain error — held last-good mix and engaged SAFE bypass. (${(e as Error).message})`)
        this.engine.setBypass(true)
      }
    }
  }

  private tick() {
    const st = this.store.getState()
    const ctx = this.engine.ctx
    const scene = SCENES[st.sceneId]
    const live = st.mixMode === 'live'
    const aggressiveness = live ? 0.5 : 1
    const maxFaderStep = live ? 0.4 : 1.5
    const sceneFaderStep = st.sceneTransition?.to === st.sceneId ? 2 : maxFaderStep
    const maxEqStep = live ? 0.3 : 1.0

    const scope = st.recallScope
    const dcaLevels = st.dcaGroups
    const muteGroups = st.muteGroups
    const mixMinusId = st.mixMinusChannelId

    // sync global controls
    if (st.bypassed !== this.prevBypass) { this.engine.setBypass(st.bypassed); this.prevBypass = st.bypassed }
    if (st.monitorSource !== this.prevMonitor) { this.engine.setMonitor(st.monitorSource as any); this.prevMonitor = st.monitorSource }
    const oscKey = `${st.oscillator.on}|${st.oscillator.type}|${st.oscillator.dest}|${st.oscillator.levelDb}`
    if (oscKey !== this.prevOscKey) {
      this.engine.setOscillator(st.oscillator.on, st.oscillator.type, st.oscillator.dest, st.oscillator.levelDb)
      this.prevOscKey = oscKey
    }

    const frozen = st.frozen
    const safeActive = st.bypassed
    const automationHeld = frozen || safeActive

    // A scene selected during FREEZE or SAFE is queued visibly, but none of its
    // automatic processing reaches even the background program chain until the
    // operator releases the hold.
    if (this.prevScene !== st.sceneId && !automationHeld) {
      this.engine.loudness.port.postMessage({ type: 'config', targetLufs: scene.masterTargetLufs, ceilingDb: -1 })
      ramp(this.engine.reverbReturn.gain, dbToGain(scene.reverbReturnDb), ctx, 0.5)
      if (this.prevScene !== null) st.pushLog('scene', `Scene → ${scene.name}: ${scene.blurb}`)
      this.prevScene = st.sceneId
    }

    if (frozen && !this.prevFrozen) st.pushLog('safety', 'FREEZE engaged — AI holding all parameters.')
    if (!frozen && this.prevFrozen) st.pushLog('safety', 'FREEZE released — AI resuming.')
    this.prevFrozen = frozen
    let sceneSettled = true

    // cross-channel masking decisions (uses last tick's per-channel band energies +
    // effective labels, so every channel sees the full picture before it acts)
    const maskInputs: MaskInput[] = this.engine.channels.map((ch) => {
      const b = this.state.get(ch.id)!
      return { id: ch.id, cls: b.effCls, active: b.lastActive, energy: b.bandEnergy }
    })
    const maskDecisions: Map<number, MaskDecision[]> = automationHeld
      ? new Map<number, MaskDecision[]>()
      : computeMasking(maskInputs, scene.speechActive)

    const display: ChannelModel[] = []
    const doDisplay = this.tickCount % 3 === 0

    for (const ch of this.engine.channels) {
      const b = this.state.get(ch.id)!
      const model = st.channels.find((m) => m.id === ch.id)
      if (!model) continue

      // repatch detected -> re-acquire identity from scratch (new source on this channel)
      if (b.lastPatchedInputId !== ch.patchedInputId) {
        b.clsState = createClsState()
        b.scores = {}
        b.cls = 'unknown'
        b.candidate = 'unknown'
        b.candCount = 0
        b.ltas = null
        b.bandEnergy = MASK_BANDS.map(() => 0)
        b.noiseFloorDb = -60 // fresh floor estimate for the new source
        b.slowPreDb = -40
        b.notchHz = 0
        b.voiceConf = 0
        b.maskGain = MASK_BANDS.map(() => 0)
        b.lastPatchedInputId = ch.patchedInputId
        if (!model.labelLocked) st.pushLog('label', `${model.name}: input changed — re-identifying…`)
      }

      // --- measure ---
      ch.preAnalyser.getFloatTimeDomainData(b.timeBuf)
      ch.preAnalyser.getFloatFrequencyData(b.freqBuf)
      for (let i = 0; i < b.freqBuf.length; i++) if (!isFinite(b.freqBuf[i])) b.freqBuf[i] = -140
      const preDb = fixNeg(rmsDb(b.timeBuf))
      const prePk = fixNeg(peakDb(b.timeBuf))
      // noise floor tracker
      if (preDb < b.noiseFloorDb) b.noiseFloorDb = preDb
      else b.noiseFloorDb = Math.min(-25, b.noiseFloorDb + 0.02)
      const active = preDb > b.noiseFloorDb + 12
      if (active) b.slowPreDb = 0.96 * b.slowPreDb + 0.04 * preDb

      ch.postAnalyser.getFloatTimeDomainData(b.timeBuf)
      const postDb = fixNeg(rmsDb(b.timeBuf))
      const postPk = fixNeg(peakDb(b.timeBuf))
      if (prePk > -0.3 || postPk > -0.3) b.clipHold = 30
      else if (b.clipHold > 0) b.clipHold--

      // --- classify (continuous, smoothed) ---
      const f = extractFeatures(b.freqBuf, ctx.sampleRate, ch.preAnalyser.fftSize, b.clsState, active)
      if (active && !automationHeld) {
        const { scores } = classify(f)
        for (const k in scores) {
          const key = k as SourceClass
          b.scores[key] = 0.9 * (b.scores[key] ?? 0) + 0.1 * (scores[key] ?? 0)
        }
        let best: SourceClass = 'unknown'; let bp = -1
        for (const k in b.scores) { const v = b.scores[k as SourceClass]!; if (v > bp) { bp = v; best = k as SourceClass } }
        b.confidence = bp
        if (!model.labelLocked && best !== 'unknown') {
          if (b.cls === 'unknown') {
            b.cls = best // acquire fast on first lock-on
          } else if (best !== b.cls) {
            // commit a label change only after it is stable for ~0.4 s and confident
            if (best === b.candidate) b.candCount++
            else { b.candidate = best; b.candCount = 1 }
            if (b.candCount >= 8 && bp > 0.5) {
              b.cls = best
              b.candCount = 0
              st.pushLog('label', `Re-labeled ${model.name}: ${PROFILES[best].label} (${Math.round(bp * 100)}%)`)
            }
          } else {
            b.candCount = 0
          }
        }
      }
      const cls: SourceClass = model.labelLocked ? model.cls : (b.cls === 'unknown' ? ch.patchedClass : b.cls)
      const profile = PROFILES[cls]

      // route to bus on change (non-speech)
      if (!ch.isSpeech && b.routedBus !== profile.bus) {
        this.engine.routeToBus(ch, profile.bus)
        b.routedBus = profile.bus
      }

      // long-term spectrum (slow — a stable average is what makes the EQ settle)
      b.ltas = updateLtas(b.ltas, b.freqBuf, 0.012)

      // store masking inputs for next tick (so every channel sees the full picture)
      b.effCls = cls
      b.lastActive = active
      b.bandEnergy = bandEnergyOf(b.ltas, ctx.sampleRate / ch.preAnalyser.fftSize)

      // --- operator input section & groups (always applied; survives FREEZE) ---
      ramp(ch.polarity.gain, model.polarityInv ? -1 : 1, ctx, 0.005)
      ramp(ch.inputDelay.delayTime, clamp(model.inputDelayMs / 1000, 0, 0.1), ctx, 0.05)
      const dcaDb = dcaLevels.find((d) => d.id === model.dca)?.levelDb ?? 0
      ramp(ch.dcaGain.gain, dbToGain(dcaDb), ctx, 0.08)
      const groupMuted = model.muteGroup > 0 && !!muteGroups[model.muteGroup - 1]
      ramp(ch.mute.gain, model.muted || groupMuted ? 0 : 1, ctx, 0.02)
      ramp(ch.soloSend.gain, model.soloed ? 1 : 0, ctx, 0.02)
      ramp(ch.mixMinusSend.gain, mixMinusId === ch.id ? 0 : 1, ctx, 0.05)

      if (!automationHeld) {
        // --- trim (normalize to ~ -18 dBFS) ---
        if (!model.overrides.trim && scope.levels) {
          const trimTarget = clamp(-18 - b.slowPreDb, -6, 24)
          b.curTrim = approach(b.curTrim, trimTarget, 1.5)
          ramp(ch.trim.gain, dbToGain(b.curTrim), ctx, 0.3)
        }
        // --- HPF ---
        if (!model.overrides.hpf && scope.eq) ramp(ch.hpf.frequency, profile.hpfHz, ctx, 0.2)
        // --- gate ---
        if (!model.overrides.gate && scope.dynamics) {
          const thr = clamp(b.noiseFloorDb + profile.gate.offsetDb, -60, -10)
          if (b.lastGateEnabled !== profile.gate.enabled || Math.abs(thr - b.lastGateThresh) > 0.8) {
            ch.gate.port.postMessage({
              type: 'params', enabled: profile.gate.enabled, thresholdDb: thr,
              ratio: profile.gate.ratio, rangeDb: profile.gate.rangeDb,
            })
            b.lastGateThresh = thr; b.lastGateEnabled = profile.gate.enabled
          }
        }
        // --- compressor ---
        if (!model.overrides.comp && scope.dynamics) {
          ramp(ch.comp.threshold, profile.comp.thresholdDb, ctx, 0.2)
          ch.comp.ratio.value = profile.comp.ratio
          ch.comp.attack.value = profile.comp.attack
          ch.comp.release.value = profile.comp.release
          ch.comp.knee.value = profile.comp.knee
        }
        // --- EQ (corrective + voicing) ---
        // settle a confidence so voicing doesn't breathe with every wiggle, and only
        // RE-MEASURE the corrective curve ~2x/sec; the filter ramps slowly between.
        if (!model.overrides.eq && scope.eq) {
          const confTarget = model.labelLocked || b.confidence > 0.6 ? 1 : Math.max(0.3, b.confidence)
          b.voiceConf = approach(b.voiceConf, confTarget, 0.03)
          if (this.tickCount % 10 === 0) {
            const eq = computeEq(profile, b.ltas, ctx.sampleRate, ch.preAnalyser.fftSize, b.voiceConf, aggressiveness, b.notchHz)
            b.notchHz = eq.notchHz
            b.resonanceHz = eq.resonanceHz
            eq.corr.forEach((c, i) => {
              ramp(ch.corr[i].frequency, c.freq, ctx, 0.5)
              ramp(ch.corr[i].gain, c.gainDb, ctx, 0.5)
              ch.corr[i].Q.value = c.q
            })
            eq.voice.forEach((v, i) => {
              ch.voice[i].type = v.type
              ramp(ch.voice[i].frequency, v.freq, ctx, 0.6)
              ramp(ch.voice[i].gain, v.gainDb, ctx, 0.5)
              ch.voice[i].Q.value = v.q
            })
            b.baseBands = eq.bands
          }
        }
        // --- cross-channel masking carve (slewed, so carves ease in/out) ---
        if (!model.overrides.eq && scope.eq) {
          const decs = maskDecisions.get(ch.id) ?? []
          const maskBands: typeof b.baseBands = []
          let strongest: MaskDecision | null = null
          for (let bi = 0; bi < MASK_BANDS.length; bi++) {
            const dec = decs.find((d) => d.bandIdx === bi)
            const target = dec && dec.gainDb < -0.3 ? dec.gainDb : 0
            b.maskGain[bi] = approach(b.maskGain[bi], target, 0.12) // ~2.4 dB/s
            const band = MASK_BANDS[bi]
            if (b.maskGain[bi] < -0.2) {
              ramp(ch.mask[bi].frequency, band.hz, ctx, 0.4)
              ramp(ch.mask[bi].gain, b.maskGain[bi], ctx, 0.4)
              ch.mask[bi].Q.value = band.q
              maskBands.push({ type: 'peaking', freq: band.hz, gainDb: b.maskGain[bi], q: band.q, kind: 'mask' })
              if (dec && (!strongest || dec.gainDb < strongest.gainDb)) strongest = dec
            } else {
              ramp(ch.mask[bi].gain, 0, ctx, 0.4)
            }
          }
          model.eqBands = maskBands.length ? [...b.baseBands, ...maskBands] : b.baseBands
          if (strongest) {
            b.maskInfo = { db: strongest.gainDb, hz: MASK_BANDS[strongest.bandIdx].hz, winner: strongest.winnerCls }
            const key = decs.map((d) => `${d.bandIdx}:${d.winnerCls}`).join(',')
            if (key !== b.maskKey) {
              b.maskKey = key
              const parts = decs
                .map((d) => `−${(-d.gainDb).toFixed(1)}dB@${MASK_BANDS[d.bandIdx].hz}Hz for ${d.winnerCls ? PROFILES[d.winnerCls].label : 'mix'}`)
                .join(' & ')
              st.pushLog('eq', `Masking: ${PROFILES[cls].label} dipped ${parts}`)
            }
          } else {
            b.maskInfo = null
            b.maskKey = ''
          }
        }
        // --- de-esser (dynamic) ---
        if (!model.overrides.deess && scope.eq) {
          const target = deEssGain(b.ltas, b.freqBuf, ctx.sampleRate / ch.preAnalyser.fftSize, profile.deEss)
          b.curDeEss = approach(b.curDeEss, target, Math.min(maxEqStep, 0.25))
          ramp(ch.deEss.gain, b.curDeEss, ctx, 0.2)
        }
        // --- fader (scene balance + loudness ride; scene-safe channels hold level) ---
        if (scope.levels) {
          if (model.overrides.fader) {
            ramp(ch.fader.gain, dbToGain(clamp(model.faderDb, -60, 6)), ctx, 0.05)
            b.curFader = model.faderDb
          } else {
            const sceneT = scene.classTargets[cls]
            const dca = scene.dca[dcaGroup(profile.bus)]
            const sceneOffset = model.sceneSafe ? 0 : (sceneT?.faderDb ?? 0) + dca
            let faderTarget = -3 + sceneOffset
            if (active) faderTarget += clamp((profile.targetRmsDb - postDb) * 0.12, -2.5, 2.5)
            faderTarget = clamp(faderTarget, -60, 6)
            b.curFader = approach(b.curFader, faderTarget, sceneFaderStep)
            if (st.sceneTransition?.to === st.sceneId &&
                Math.abs(b.curFader - faderTarget) > 0.5) {
              sceneSettled = false
            }
            ramp(ch.fader.gain, dbToGain(b.curFader), ctx, 0.25)
          }
        }
        // --- pan ---
        if (!model.overrides.pan && scope.levels && ch.panner) {
          b.curPan = approach(b.curPan, profile.pan * 0.7, 0.05)
          ramp(ch.panner.pan, b.curPan, ctx, 0.3)
        }
        // --- FX sends (reverb + delay throwback) ---
        if (scope.routing) {
          if (model.overrides.reverb) {
            ramp(ch.reverbSend.gain, model.reverbSendDb <= -50 ? 0 : dbToGain(model.reverbSendDb), ctx, 0.2)
            ramp(ch.delaySend.gain, model.delaySendDb <= -50 ? 0 : dbToGain(model.delaySendDb), ctx, 0.2)
          } else {
            const rv = model.sceneSafe ? -60 : scene.classTargets[cls]?.reverbSendDb ?? -14
            const dl = !model.sceneSafe && cls === 'leadVocal' && !scene.speechActive ? -15 : -60
            ramp(ch.reverbSend.gain, rv <= -50 ? 0 : dbToGain(rv), ctx, 0.4)
            ramp(ch.delaySend.gain, dl <= -50 ? 0 : dbToGain(dl), ctx, 0.4)
            model.reverbSendDb = rv
            model.delaySendDb = dl
          }
        }
      }

      // reason string
      const moves: string[] = []
      moves.push(`${PROFILES[cls].label} ${Math.round((model.labelLocked ? 1 : b.confidence) * 100)}%`)
      if (b.resonanceHz) moves.push(`notch ${Math.round(b.resonanceHz)}Hz`)
      if (profile.deEss && b.curDeEss < -0.5) moves.push(`de-ess ${b.curDeEss.toFixed(1)}dB`)
      if (b.maskInfo) moves.push(`dip ${b.maskInfo.db.toFixed(1)}@${b.maskInfo.hz} vs ${b.maskInfo.winner ? PROFILES[b.maskInfo.winner].label : 'mix'}`)
      if (ch.isSpeech) moves.push(`automix ${fmt(ch.automixGainDb)}dB`)
      moves.push(`${fmt(b.curFader)}dB`)
      b.reason = automationHeld
        ? safeActive ? 'SAFE — automation held' : 'FROZEN — holding'
        : moves.join(' · ')

      if (doDisplay) {
        display.push({
          ...model,
          cls,
          confidence: model.labelLocked ? 1 : b.confidence,
          bus: profile.bus,
          preRmsDb: preDb,
          postRmsDb: postDb,
          noiseFloorDb: b.noiseFloorDb,
          trimDb: b.curTrim,
          hpfHz: profile.hpfHz,
          gateThreshDb: b.lastGateThresh,
          gateOpen: ch.gateOpen,
          gateGrDb: ch.gateGrDb,
          compThreshDb: profile.comp.thresholdDb,
          compRatio: profile.comp.ratio,
          compGrDb: (ch.comp as any).reduction ?? 0,
          faderDb: b.curFader,
          pan: b.curPan,
          reverbSendDb: model.reverbSendDb,
          delaySendDb: model.delaySendDb,
          deEssDb: b.curDeEss,
          eqBands: model.eqBands,
          automixGainDb: ch.automixGainDb,
          clip: b.clipHold > 0,
          reason: b.reason,
          active,
        })
      }
    }

    const transition = st.sceneTransition
    if (transition?.to === st.sceneId &&
        !automationHeld &&
        sceneSettled &&
        Date.now() - transition.startedAtMs >= 1_750) {
      st.completeSceneTransition(st.sceneId)
      st.pushLog('scene', `${scene.name} scene settled — control ramps converged.`)
    }

    const loudness = this.engine.loudnessTel
    if (!automationHeld &&
        loudness.short > -45 &&
        loudness.momentary > -45) {
      const loudnessError = clamp(scene.masterTargetLufs - loudness.short, -6, 6)
      if (Math.abs(loudnessError) > 0.25) {
        const correction = clamp(
          loudnessError * (live ? 0.01 : 0.02),
          live ? -0.02 : -0.05,
          live ? 0.02 : 0.05,
        )
        this.masterTrimDb = clamp(this.masterTrimDb + correction, -12, 6)
        ramp(
          this.engine.masterTrim.gain,
          dbToGain(this.masterTrimDb),
          ctx,
          live ? 0.5 : 0.25,
        )
      }
    }

    if (doDisplay) {
      st.setChannels(display)
      const t = this.engine.loudnessTel
      const corr = this.engine.readCorrelation()
      st.setMaster({
        momentaryLufs: t.momentary, shortLufs: t.short, integratedLufs: t.integrated,
        truePeakDb: t.truePeak, limiterGrDb: t.grDb, targetLufs: scene.masterTargetLufs,
        limiterInputTruePeakDb: t.inputTruePeak, masterTrimDb: this.masterTrimDb,
        ceilingDb: t.ceiling, glueGrDb: this.engine.glueGrDb(),
        correlation: corr, clip: t.truePeak > t.ceiling + 0.1,
      })
      const mx = this.engine.readMatrixLevels()
      st.setMatrixMeter('stream', mx.stream)
      st.setMatrixMeter('record', mx.record)
      st.setMatrixMeter('assist', mx.assist)
      st.setMatrixMeter('mixminus', mx.mixminus)
    }
    this.tickCount++
  }
}
