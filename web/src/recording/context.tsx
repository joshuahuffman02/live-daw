import { createContext, useContext } from 'react'
import type { BrowserRecordingController } from './controller'

const RecordingControllerContext = createContext<BrowserRecordingController | null>(null)

export const RecordingControllerProvider = RecordingControllerContext.Provider

export function useRecordingController(): BrowserRecordingController {
  const controller = useContext(RecordingControllerContext)
  if (!controller) throw new Error('Recording controller is not available.')
  return controller
}
