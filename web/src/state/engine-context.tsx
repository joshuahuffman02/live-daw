import { createContext, useContext } from 'react'
import type { AudioEngine } from '../audio/engine'

const EngineContext = createContext<AudioEngine | null>(null)

export const EngineProvider = EngineContext.Provider

export function useEngine(): AudioEngine {
  const e = useContext(EngineContext)
  if (!e) throw new Error('useEngine must be used inside <EngineProvider>')
  return e
}
