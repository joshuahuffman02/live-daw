import { useRef, useState } from 'react'
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

export default function App() {
  const [engine, setEngine] = useState<AudioEngine | null>(null)
  const [booting, setBooting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const brainRef = useRef<Brain | null>(null)
  const channels = useStore((s) => s.channels)

  async function start(mode: InputMode) {
    setBooting(true)
    setError(null)
    try {
      const e = new AudioEngine()
      await e.init()
      if (mode === 'mic') await e.buildMic()
      else await e.buildSynthetic()
      await e.resume()
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
    } catch (err) {
      setError((err as Error).message || 'Failed to start audio engine.')
    } finally {
      setBooting(false)
    }
  }

  function stop() {
    brainRef.current?.stop()
    engine?.dispose()
    brainRef.current = null
    setEngine(null)
    useStore.getState().reset()
  }

  if (!engine) {
    return <StartScreen onStart={start} booting={booting} error={error} />
  }

  return (
    <EngineProvider value={engine}>
      <div className="relative flex h-screen flex-col bg-[#0a0b0e] text-zinc-200">
        <TopBar onStop={stop} />
        <SceneTimeline />
        <div className="flex min-h-0 flex-1">
          <div className="rack flex flex-1 gap-2 overflow-x-auto p-3">
            {channels.map((c) => (
              <ChannelStrip key={c.id} id={c.id} />
            ))}
          </div>
          <div className="flex w-[340px] shrink-0 flex-col gap-3 overflow-y-auto border-l border-[#1c1f27] bg-[#0c0d11] p-3">
            <MasterPanel />
            <ChannelDetail />
            <BrainLog />
          </div>
        </div>
        <ConsoleBar />
        <PatchPanel />
        <DevicesPanel />
      </div>
    </EngineProvider>
  )
}
