import type { AudioEngine } from '../audio/engine'
import { useStore } from '../store'
import {
  BrowserRecordingLease,
  BrowserRecordingLibrary,
  type BrowserRecordingAsset,
  type BrowserRecordingSession,
} from './session-library'

export class BrowserRecordingController {
  private readonly library = new BrowserRecordingLibrary()
  private readonly lease = new BrowserRecordingLease()
  private engine: AudioEngine | null = null
  private activeSession: BrowserRecordingSession | null = null
  private nextSequence = 0
  private writeQueue: Promise<void> = Promise.resolve()
  private writeError: Error | null = null
  private stopping = false
  private objectURLs = new Set<string>()
  private initialized = false
  private initializationPromise: Promise<void> | null = null

  async initialize(): Promise<void> {
    if (this.initialized) return
    if (!this.initializationPromise) {
      this.initializationPromise = (async () => {
        try {
          await this.library.initialize()
          const recovery = await this.lease.runIfAvailable(() => this.library.recoverInterruptedSessions())
          const recovered = recovery.value ?? 0
          this.initialized = true
          await this.refresh(recovered > 0
            ? `Recovered ${recovered} interrupted session${recovered === 1 ? '' : 's'}`
            : recovery.acquired ? undefined : 'Another tab owns the active recording')
        } catch (error) {
          this.reportError(error, 'Recording library unavailable')
        } finally {
          this.initializationPromise = null
        }
      })()
    }
    await this.initializationPromise
  }

  attachEngine(engine: AudioEngine): void {
    this.engine = engine
  }

  detachEngine(): void {
    this.engine = null
  }

  async start(name = '', continuedFromSessionId: string | null = null): Promise<void> {
    if (!this.engine) throw this.reportError(new Error('Start the audio engine before recording.'), 'Recorder unavailable')
    if (this.activeSession || this.engine.isRecording()) {
      throw this.reportError(new Error('A recording session is already active.'), 'Recorder busy')
    }
    try {
      await this.lease.acquire()
      await this.library.recoverInterruptedSessions()
      this.writeQueue = Promise.resolve()
      this.writeError = null
      this.nextSequence = 0

      // MediaRecorder chooses its final mime type at construction time. Start it
      // first, then create the durable manifest immediately; no audio callback is
      // blocked by IndexedDB work.
      let mimeType = 'audio/webm'
      const pendingChunks: Blob[] = []
      let sessionReady = false
      mimeType = this.engine.startRecording(
        (chunk) => {
          if (!sessionReady) pendingChunks.push(chunk)
          else this.enqueueChunk(chunk)
        },
        (message) => this.failActiveRecording(new Error(message)),
      )
      const session = await this.library.createCaptureSession(name, mimeType, continuedFromSessionId)
      this.activeSession = session
      sessionReady = true
      pendingChunks.forEach((chunk) => this.enqueueChunk(chunk))
      useStore.getState().setRecording(true, session.id)
      useStore.getState().setRecordingLibraryStatus('Recording to durable browser storage')
      await this.refresh()
    } catch (error) {
      try { await this.engine?.stopRecording() } catch { /* best effort */ }
      this.activeSession = null
      this.lease.release()
      useStore.getState().setRecording(false, null)
      throw this.reportError(error, 'Could not start recording')
    }
  }

  async stop(reason: string | null = null): Promise<void> {
    if (this.stopping) return
    const session = this.activeSession
    if (!session) return
    this.stopping = true
    try {
      await this.engine?.stopRecording()
      try {
        await this.writeQueue
      } catch (error) {
        this.writeError = asError(error)
      }
      const durationMs = Date.now() - (session.startedAtMs ?? Date.now())
      const failure = reason ?? this.writeError?.message ?? null
      await this.library.finalizeCapture(session.id, durationMs, failure)
      useStore.getState().setRecordingLibraryStatus(
        failure ? `Recording needs attention · ${failure}` : 'Session saved',
        failure,
      )
    } catch (error) {
      this.reportError(error, 'Could not finalize recording')
    } finally {
      this.activeSession = null
      this.nextSequence = 0
      this.lease.release()
      useStore.getState().setRecording(false, null)
      this.stopping = false
      await this.refresh()
    }
  }

  async continueSession(sessionId: string): Promise<void> {
    const source = useStore.getState().recordingSessions.find((session) => session.id === sessionId)
    if (!source) throw this.reportError(new Error('That session no longer exists.'), 'Cannot continue session')
    await this.start(`${source.name} · continuation`, source.id)
  }

  async importFiles(files: File[], name?: string): Promise<void> {
    try {
      if (this.activeSession) throw new Error('Stop the active recording before importing audio.')
      useStore.getState().setRecordingLibraryStatus(`Importing ${files.length} file${files.length === 1 ? '' : 's'}…`)
      const imported = await this.lease.runIfAvailable(() => this.library.importFiles(files, name))
      if (!imported.acquired || !imported.value) {
        throw new Error('Another AutoMix tab is recording. Stop it before importing audio.')
      }
      const session = imported.value
      await this.refresh('Import complete')
      useStore.getState().selectRecordingSession(session.id)
    } catch (error) {
      throw this.reportError(error, 'Import failed')
    }
  }

  async updateSession(sessionId: string, name: string, notes: string): Promise<void> {
    try {
      await this.library.updateSession(sessionId, name, notes)
      await this.refresh('Session details saved')
      useStore.getState().selectRecordingSession(sessionId)
    } catch (error) {
      throw this.reportError(error, 'Could not save session')
    }
  }

  async deleteSession(sessionId: string): Promise<void> {
    try {
      const deleted = await this.lease.runIfAvailable(() => this.library.deleteSession(sessionId))
      if (!deleted.acquired) {
        throw new Error('Another AutoMix tab is recording. Stop it before deleting stored audio.')
      }
      await this.refresh('Session deleted from this browser')
    } catch (error) {
      throw this.reportError(error, 'Could not delete session')
    }
  }

  async assetURL(sessionId: string, asset: BrowserRecordingAsset): Promise<string> {
    try {
      const blob = await this.library.assetBlob(sessionId, asset.id, asset.mimeType)
      const url = URL.createObjectURL(blob)
      this.objectURLs.add(url)
      return url
    } catch (error) {
      throw this.reportError(error, 'Could not open recorded audio')
    }
  }

  revokeAssetURL(url: string): void {
    if (!this.objectURLs.delete(url)) return
    URL.revokeObjectURL(url)
  }

  reportPlaybackFailure(name: string): void {
    this.reportError(new Error(`This browser could not decode ${name}. The stored file was not removed.`), 'Playback failed')
  }

  async refresh(status?: string): Promise<void> {
    try {
      const sessions = await this.library.listSessions()
      useStore.getState().setRecordingSessions(sessions)
      useStore.getState().setRecordingLibraryStatus(
        status ?? `${sessions.length} session${sessions.length === 1 ? '' : 's'} stored in this browser`,
      )
    } catch (error) {
      this.reportError(error, 'Could not refresh recording sessions')
    }
  }

  async recoverAndRefresh(): Promise<void> {
    if (this.activeSession) {
      await this.refresh()
      return
    }
    try {
      const recovery = await this.lease.runIfAvailable(() => this.library.recoverInterruptedSessions())
      await this.refresh(recovery.acquired && (recovery.value ?? 0) > 0
        ? `Recovered ${recovery.value} interrupted session${recovery.value === 1 ? '' : 's'}`
        : recovery.acquired ? undefined : 'Another tab owns the active recording')
    } catch (error) {
      this.reportError(error, 'Could not refresh recording sessions')
    }
  }

  async dispose(): Promise<void> {
    await this.stop('The audio engine stopped before the operator ended the recording.')
    this.objectURLs.forEach((url) => URL.revokeObjectURL(url))
    this.objectURLs.clear()
    this.lease.release()
    this.library.close()
    this.initialized = false
  }

  private enqueueChunk(chunk: Blob): void {
    const session = this.activeSession
    if (!session || this.writeError) return
    const sequence = this.nextSequence++
    this.writeQueue = this.writeQueue
      .then(() => this.library.appendCaptureChunk(session.id, sequence, chunk))
      .catch((error) => {
        this.writeError = asError(error)
        void this.failActiveRecording(this.writeError)
        throw this.writeError
      })
  }

  private async failActiveRecording(error: Error): Promise<void> {
    if (this.stopping || !this.activeSession) return
    await this.stop(`Storage/recorder failure: ${error.message}`)
  }

  private reportError(error: unknown, prefix: string): Error {
    const normalized = asError(error)
    const message = `${prefix} · ${normalized.message}`
    useStore.getState().setRecordingLibraryStatus(message, normalized.message)
    return normalized
  }
}

function asError(error: unknown): Error {
  if (error instanceof Error) return error
  return new Error(String(error))
}
