export type BrowserSessionStatus = 'recording' | 'ready' | 'interrupted' | 'needsAttention'
export type BrowserSessionOrigin = 'browserCapture' | 'importedFiles'

export interface BrowserRecordingAsset {
  id: string
  name: string
  kind: 'program' | 'importedAudio'
  mimeType: string
  byteCount: number
}

export interface BrowserRecordingSession {
  schemaVersion: 1
  id: string
  name: string
  notes: string
  createdAtMs: number
  updatedAtMs: number
  startedAtMs: number | null
  endedAtMs: number | null
  status: BrowserSessionStatus
  origin: BrowserSessionOrigin
  durationMs: number
  byteCount: number
  chunkCount: number
  assets: BrowserRecordingAsset[]
  continuedFromSessionId: string | null
  error: string | null
}

interface PayloadRecord {
  key: string
  sessionId: string
  assetId: string
  sequence: number
  blob: Blob
}

const DB_NAME = 'automix-recording-library'
const DB_VERSION = 1
const SESSION_STORE = 'sessions'
const PAYLOAD_STORE = 'payloads'
const LOCK_KEY = 'automix-recording-owner-v1'
const supportedExtensions = new Set(['wav', 'wave', 'aif', 'aiff', 'caf', 'm4a', 'mp3', 'flac', 'webm', 'ogg', 'opus'])

function id(): string {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('The recording database request failed.'))
  })
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve()
    transaction.onabort = () => reject(transaction.error ?? new Error('The recording database transaction was canceled.'))
    transaction.onerror = () => reject(transaction.error ?? new Error('The recording database transaction failed.'))
  })
}

function openDatabase(): Promise<IDBDatabase> {
  if (!('indexedDB' in globalThis)) {
    return Promise.reject(new Error('This browser does not provide durable recording storage (IndexedDB).'))
  }
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION)
    request.onupgradeneeded = () => {
      const database = request.result
      if (!database.objectStoreNames.contains(SESSION_STORE)) {
        database.createObjectStore(SESSION_STORE, { keyPath: 'id' })
      }
      if (!database.objectStoreNames.contains(PAYLOAD_STORE)) {
        const payloads = database.createObjectStore(PAYLOAD_STORE, { keyPath: 'key' })
        payloads.createIndex('bySession', 'sessionId', { unique: false })
        payloads.createIndex('byAsset', ['sessionId', 'assetId'], { unique: false })
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('Could not open the recording library.'))
    request.onblocked = () => reject(new Error('Close other AutoMix tabs so the recording library can be upgraded.'))
  })
}

export class BrowserRecordingLibrary {
  private database: IDBDatabase | null = null

  async initialize(): Promise<void> {
    if (this.database) return
    this.database = await openDatabase()
    this.database.onversionchange = () => {
      this.database?.close()
      this.database = null
    }
  }

  async recoverInterruptedSessions(): Promise<number> {
    const database = await this.db()
    const transaction = database.transaction(SESSION_STORE, 'readwrite')
    const store = transaction.objectStore(SESSION_STORE)
    const sessions = await requestResult(store.getAll()) as BrowserRecordingSession[]
    let recovered = 0
    const now = Date.now()
    for (const session of sessions) {
      if (session.status !== 'recording') continue
      session.status = 'interrupted'
      session.endedAtMs = now
      session.updatedAtMs = now
      session.error = session.chunkCount > 0
        ? 'The tab closed before this recording was finalized. Saved chunks remain playable.'
        : 'The tab closed before any recording chunks were saved.'
      store.put(session)
      recovered += 1
    }
    await transactionDone(transaction)
    return recovered
  }

  async listSessions(): Promise<BrowserRecordingSession[]> {
    const database = await this.db()
    const transaction = database.transaction(SESSION_STORE, 'readonly')
    const sessions = await requestResult(transaction.objectStore(SESSION_STORE).getAll()) as BrowserRecordingSession[]
    await transactionDone(transaction)
    return sessions.sort((a, b) => {
      if (a.status === 'recording' && b.status !== 'recording') return -1
      if (b.status === 'recording' && a.status !== 'recording') return 1
      return b.createdAtMs - a.createdAtMs
    })
  }

  async createCaptureSession(
    name: string,
    mimeType: string,
    continuedFromSessionId: string | null = null,
  ): Promise<BrowserRecordingSession> {
    const now = Date.now()
    const sessionId = id()
    const session: BrowserRecordingSession = {
      schemaVersion: 1,
      id: sessionId,
      name: cleanName(name, `Browser capture · ${new Date(now).toLocaleString()}`),
      notes: '',
      createdAtMs: now,
      updatedAtMs: now,
      startedAtMs: now,
      endedAtMs: null,
      status: 'recording',
      origin: 'browserCapture',
      durationMs: 0,
      byteCount: 0,
      chunkCount: 0,
      assets: [{
        id: 'program',
        name: `automix-program-${new Date(now).toISOString().split(':').join('-')}.${extensionForMime(mimeType)}`,
        kind: 'program',
        mimeType,
        byteCount: 0,
      }],
      continuedFromSessionId,
      error: null,
    }
    await this.putSession(session)
    return session
  }

  async appendCaptureChunk(sessionId: string, sequence: number, chunk: Blob): Promise<void> {
    if (chunk.size <= 0) return
    const database = await this.db()
    const transaction = database.transaction([SESSION_STORE, PAYLOAD_STORE], 'readwrite')
    const sessions = transaction.objectStore(SESSION_STORE)
    const session = await requestResult(sessions.get(sessionId)) as BrowserRecordingSession | undefined
    if (!session || session.status !== 'recording') {
      transaction.abort()
      throw new Error('The active recording session is no longer writable.')
    }
    transaction.objectStore(PAYLOAD_STORE).put({
      key: `${sessionId}:program:${sequence.toString().padStart(10, '0')}`,
      sessionId,
      assetId: 'program',
      sequence,
      blob: chunk,
    } satisfies PayloadRecord)
    session.chunkCount = Math.max(session.chunkCount, sequence + 1)
    session.byteCount += chunk.size
    session.updatedAtMs = Date.now()
    session.assets[0] = { ...session.assets[0], byteCount: session.assets[0].byteCount + chunk.size }
    sessions.put(session)
    await transactionDone(transaction)
  }

  async finalizeCapture(sessionId: string, durationMs: number, error: string | null = null): Promise<void> {
    const session = await this.getSession(sessionId)
    if (!session) throw new Error('The active recording session could not be found.')
    const now = Date.now()
    session.status = error || session.chunkCount === 0 ? 'needsAttention' : 'ready'
    session.error = error ?? (session.chunkCount === 0 ? 'The recorder stopped before it produced audio data.' : null)
    session.durationMs = Math.max(0, durationMs)
    session.endedAtMs = now
    session.updatedAtMs = now
    await this.putSession(session)
  }

  async importFiles(files: File[], name?: string): Promise<BrowserRecordingSession> {
    if (files.length === 0) throw new Error('Choose at least one audio file.')
    for (const file of files) validateImport(file)
    const totalBytes = files.reduce((sum, file) => sum + file.size, 0)
    if (navigator.storage?.estimate) {
      const estimate = await navigator.storage.estimate()
      if (estimate.quota != null && estimate.usage != null && estimate.quota - estimate.usage < totalBytes + 100_000_000) {
        throw new Error('There is not enough browser storage to import these files with a 100 MB reserve.')
      }
    }

    const now = Date.now()
    const sessionId = id()
    const assets: BrowserRecordingAsset[] = files.map((file) => ({
      id: id(),
      name: file.name,
      kind: 'importedAudio',
      mimeType: file.type || mimeFromName(file.name),
      byteCount: file.size,
    }))
    const session: BrowserRecordingSession = {
      schemaVersion: 1,
      id: sessionId,
      name: cleanName(name ?? '', files.length === 1 ? stripExtension(files[0].name) : 'Imported recordings'),
      notes: '',
      createdAtMs: now,
      updatedAtMs: now,
      startedAtMs: null,
      endedAtMs: now,
      status: 'ready',
      origin: 'importedFiles',
      durationMs: 0,
      byteCount: totalBytes,
      chunkCount: files.length,
      assets,
      continuedFromSessionId: null,
      error: null,
    }

    const database = await this.db()
    const transaction = database.transaction([SESSION_STORE, PAYLOAD_STORE], 'readwrite')
    transaction.objectStore(SESSION_STORE).put(session)
    files.forEach((file, index) => {
      const asset = assets[index]
      transaction.objectStore(PAYLOAD_STORE).put({
        key: `${sessionId}:${asset.id}:0000000000`,
        sessionId,
        assetId: asset.id,
        sequence: 0,
        blob: file,
      } satisfies PayloadRecord)
    })
    await transactionDone(transaction)
    return session
  }

  async updateSession(sessionId: string, name: string, notes: string): Promise<void> {
    const session = await this.getSession(sessionId)
    if (!session) throw new Error('That recording session no longer exists.')
    if (session.status === 'recording') throw new Error('Stop recording before editing session details.')
    session.name = cleanName(name, session.name)
    session.notes = notes.trim().slice(0, 2_000)
    session.updatedAtMs = Date.now()
    await this.putSession(session)
  }

  async deleteSession(sessionId: string): Promise<void> {
    const session = await this.getSession(sessionId)
    if (!session) return
    if (session.status === 'recording') throw new Error('Stop recording before deleting its session.')
    const database = await this.db()
    const transaction = database.transaction([SESSION_STORE, PAYLOAD_STORE], 'readwrite')
    transaction.objectStore(SESSION_STORE).delete(sessionId)
    const index = transaction.objectStore(PAYLOAD_STORE).index('bySession')
    const cursorRequest = index.openCursor(IDBKeyRange.only(sessionId))
    cursorRequest.onsuccess = () => {
      const cursor = cursorRequest.result
      if (!cursor) return
      cursor.delete()
      cursor.continue()
    }
    await transactionDone(transaction)
  }

  async assetBlob(sessionId: string, assetId: string, mimeType: string): Promise<Blob> {
    const database = await this.db()
    const transaction = database.transaction(PAYLOAD_STORE, 'readonly')
    const records = await requestResult(
      transaction.objectStore(PAYLOAD_STORE).index('byAsset').getAll(IDBKeyRange.only([sessionId, assetId])),
    ) as PayloadRecord[]
    await transactionDone(transaction)
    records.sort((a, b) => a.sequence - b.sequence)
    if (records.length === 0) throw new Error('The recorded audio payload is missing.')
    return new Blob(records.map((record) => record.blob), { type: mimeType })
  }

  close(): void {
    this.database?.close()
    this.database = null
  }

  private async db(): Promise<IDBDatabase> {
    await this.initialize()
    return this.database!
  }

  private async getSession(sessionId: string): Promise<BrowserRecordingSession | undefined> {
    const database = await this.db()
    const transaction = database.transaction(SESSION_STORE, 'readonly')
    const session = await requestResult(transaction.objectStore(SESSION_STORE).get(sessionId)) as BrowserRecordingSession | undefined
    await transactionDone(transaction)
    return session
  }

  private async putSession(session: BrowserRecordingSession): Promise<void> {
    const database = await this.db()
    const transaction = database.transaction(SESSION_STORE, 'readwrite')
    transaction.objectStore(SESSION_STORE).put(session)
    await transactionDone(transaction)
  }
}

interface RecordingLease {
  owner: string
  expiresAtMs: number
}

export class BrowserRecordingLease {
  readonly owner = id()
  private timer: number | null = null
  private webLockRelease: (() => void) | null = null

  async acquire(): Promise<void> {
    if (navigator.locks?.request) {
      await new Promise<void>((resolve, reject) => {
        void navigator.locks.request(LOCK_KEY, { mode: 'exclusive', ifAvailable: true }, async (lock) => {
          if (!lock) {
            reject(new Error('Another AutoMix tab is recording. Stop it before starting a new session.'))
            return
          }
          await new Promise<void>((release) => {
            this.webLockRelease = release
            resolve()
          })
        }).catch(reject)
      })
      return
    }

    this.acquireFallback()
  }

  async runIfAvailable<T>(work: () => Promise<T>): Promise<{ acquired: boolean; value?: T }> {
    if (navigator.locks?.request) {
      let acquired = false
      let value: T | undefined
      await navigator.locks.request(LOCK_KEY, { mode: 'exclusive', ifAvailable: true }, async (lock) => {
        if (!lock) return
        acquired = true
        value = await work()
      })
      return { acquired, value }
    }
    try {
      this.acquireFallback()
    } catch {
      return { acquired: false }
    }
    try {
      return { acquired: true, value: await work() }
    } finally {
      this.releaseFallback()
    }
  }

  private acquireFallback(): void {
    // Older browsers do not expose Web Locks. A short renewable lease is the
    // fallback; stale ownership expires automatically after a crashed tab.
    const existing = this.read()
    if (existing && existing.owner !== this.owner && existing.expiresAtMs > Date.now()) {
      throw new Error('Another AutoMix tab is recording. Stop it or wait for its 10-second lease to expire.')
    }
    this.write()
    const confirmed = this.read()
    if (!confirmed || confirmed.owner !== this.owner) {
      throw new Error('Another AutoMix tab acquired the recorder at the same time. Try again.')
    }
    this.timer = window.setInterval(() => this.write(), 3_000)
  }

  release(): void {
    this.webLockRelease?.()
    this.webLockRelease = null
    this.releaseFallback()
  }

  private releaseFallback(): void {
    if (this.timer != null) window.clearInterval(this.timer)
    this.timer = null
    const existing = this.read()
    if (existing?.owner === this.owner) localStorage.removeItem(LOCK_KEY)
  }

  private write(): void {
    localStorage.setItem(LOCK_KEY, JSON.stringify({ owner: this.owner, expiresAtMs: Date.now() + 10_000 }))
  }

  private read(): RecordingLease | null {
    try {
      const value = localStorage.getItem(LOCK_KEY)
      if (!value) return null
      const parsed = JSON.parse(value) as RecordingLease
      return typeof parsed.owner === 'string' && Number.isFinite(parsed.expiresAtMs) ? parsed : null
    } catch {
      return null
    }
  }
}

function cleanName(value: string, fallback: string): string {
  const clean = value.replace(/[\r\n\t]+/g, ' ').trim()
  return (clean || fallback).slice(0, 120)
}

function stripExtension(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(0, dot) : name
}

function validateImport(file: File): void {
  const extension = file.name.split('.').pop()?.toLowerCase() ?? ''
  if (!file.type.startsWith('audio/') && !supportedExtensions.has(extension)) {
    throw new Error(`${file.name} is not a supported audio file.`)
  }
  if (file.size <= 0) throw new Error(`${file.name} is empty.`)
}

function mimeFromName(name: string): string {
  const extension = name.split('.').pop()?.toLowerCase()
  if (extension === 'wav' || extension === 'wave') return 'audio/wav'
  if (extension === 'mp3') return 'audio/mpeg'
  if (extension === 'm4a') return 'audio/mp4'
  if (extension === 'ogg' || extension === 'opus') return 'audio/ogg'
  if (extension === 'webm') return 'audio/webm'
  if (extension === 'flac') return 'audio/flac'
  return 'audio/*'
}

function extensionForMime(mimeType: string): string {
  const normalized = mimeType.toLowerCase()
  if (normalized.includes('mp4')) return 'm4a'
  if (normalized.includes('ogg') || normalized.includes('opus')) return 'ogg'
  if (normalized.includes('wav')) return 'wav'
  return 'webm'
}
