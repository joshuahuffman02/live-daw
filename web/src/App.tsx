import { useEffect, useRef, useState } from 'react'
import { AudioEngine, type InputMode } from './audio/engine'
import { Brain, makeInitialModels } from './brain/brain'
import { useStore } from './store'
import { EngineProvider } from './state/engine-context'
import StartScreen from './components/StartScreen'
import TopBar from './components/TopBar'
import SceneTimeline from './components/SceneTimeline'
import ChannelStrip from './components/ChannelStrip'
import ChannelDetail from './components/ChannelDetail'
import MasterPanel from './components/MasterPanel'
import BrainLog from './components/BrainLog'
import ConsoleBar from './components/ConsoleBar'
import PatchPanel from './components/PatchPanel'
import DevicesPanel from './components/DevicesPanel'
import RecordingSessionsPanel from './components/RecordingSessionsPanel'
import { BrowserRecordingController } from './recording/controller'
import { RecordingControllerProvider } from './recording/context'

export default function App() {
  const [engine, setEngine] = useState<AudioEngine | null>(null)
  const [booting, setBooting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const brainRef = useRef<Brain | null>(null)
  const channels = useStore((s) => s.channels)
  const showRecordingSessions = useStore((s) => s.showRecordingSessions)
  const controllerRef = useRef<BrowserRecordingController | null>(null)
  if (!controllerRef.current) controllerRef.current = new BrowserRecordingController()
  const recordingController = controllerRef.current

  useEffect(() => {
    void recordingController.initialize()
    const warnBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!useStore.getState().recording) return
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', warnBeforeUnload)
    return () => window.removeEventListener('beforeunload', warnBeforeUnload)
  }, [recordingController])

  async function start(mode: InputMode) {
    setBooting(true)
    setError(null)
    let pendingEngine: AudioEngine | null = null
    try {
      const e = new AudioEngine()
      pendingEngine = e
      await e.init()
      if (mode === 'mic') await e.buildMic()
      else await e.buildSynthetic()
      await e.resume()
      await recordingController.initialize()
      recordingController.attachEngine(e)
      useStore.getState().initChannels(makeInitialModels(e))
      useStore.getState().setInputs(e.inputInfos())
      const pm: Record<number, number | null> = {}
      e.channels.forEach((ch) => { pm[ch.id] = ch.patchedInputId })
      useStore.getState().setPatchMap(pm)
      if (mode === 'mic') useStore.getState().setInputDeviceId(e.micDeviceId())
      useStore.getState().setStarted(true, mode)
      useStore.getState().pushLog('info', `Engine started — ${mode === 'mic' ? 'Live Microphone' : 'Synthetic Stage'} input.`)
      const brain = new Brain(e, useStore)
      brain.start()
      brainRef.current = brain
      setEngine(e)
      pendingEngine = null
    } catch (err) {
      recordingController.detachEngine()
      pendingEngine?.dispose()
      setError((err as Error).message || 'Failed to start audio engine.')
    } finally {
      setBooting(false)
    }
  }

  async function stop() {
    brainRef.current?.stop()
    await recordingController.stop()
    recordingController.detachEngine()
    engine?.dispose()
    brainRef.current = null
    setEngine(null)
    useStore.getState().reset()
  }

  if (!engine) {
    return (
      <RecordingControllerProvider value={recordingController}>
        <StartScreen
          onStart={start}
          onOpenSessions={() => useStore.getState().toggleRecordingSessions(true)}
          booting={booting}
          error={error}
        />
        {showRecordingSessions && <RecordingSessionsPanel engineReady={false} />}
      </RecordingControllerProvider>
    )
  }

  return (
    <RecordingControllerProvider value={recordingController}>
      <EngineProvider value={engine}>
        <div className="relative flex h-screen max-w-full flex-col overflow-hidden bg-[#0a0b0e] text-zinc-200">
          <TopBar onStop={stop} />
          <SceneTimeline />
          <div className="flex min-h-0 min-w-0 flex-1 flex-col lg:flex-row">
            <main aria-label="Channel mixer" className="rack order-2 flex min-h-0 min-w-0 flex-1 gap-2 overflow-x-auto p-3 lg:order-1">
              {channels.map((c) => (
                <ChannelStrip key={c.id} id={c.id} />
              ))}
            </main>
            <aside aria-label="Broadcast master and automation details" className="order-1 flex max-h-[30vh] w-full shrink-0 flex-col gap-3 overflow-y-auto border-b border-[#1c1f27] bg-[#0c0d11] p-3 lg:order-2 lg:max-h-none lg:w-[340px] lg:border-b-0 lg:border-l">
              <MasterPanel />
              <ChannelDetail />
              <BrainLog />
            </aside>
          </div>
          <ConsoleBar />
          <PatchPanel />
          <DevicesPanel />
          {showRecordingSessions && <RecordingSessionsPanel engineReady />}
        </div>
      </EngineProvider>
    </RecordingControllerProvider>
  )
}
