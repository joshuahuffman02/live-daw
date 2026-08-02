import { useCallback, useEffect, useRef, useState } from 'react'
import { useDialogFocusTrap } from '../hooks/useDialogFocusTrap'
import { useRecordingController } from '../recording/context'
import type { BrowserRecordingAsset, BrowserRecordingSession, BrowserSessionStatus } from '../recording/session-library'
import { useStore } from '../store'

export default function RecordingSessionsPanel({ engineReady }: { engineReady: boolean }) {
  const controller = useRecordingController()
  const sessions = useStore((state) => state.recordingSessions)
  const selectedId = useStore((state) => state.selectedRecordingSessionId)
  const recording = useStore((state) => state.recording)
  const activeSessionId = useStore((state) => state.activeRecordingSessionId)
  const recElapsed = useStore((state) => state.recElapsed)
  const status = useStore((state) => state.recordingLibraryStatus)
  const error = useStore((state) => state.recordingError)
  const selectSession = useStore((state) => state.selectRecordingSession)
  const togglePanel = useStore((state) => state.toggleRecordingSessions)
  const selected = sessions.find((session) => session.id === selectedId) ?? null
  const anyRecording = recording || sessions.some((session) => session.status === 'recording')
  const selectedIsLocalRecording = recording && selected?.id === activeSessionId
  const dialogRef = useRef<HTMLDivElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [newName, setNewName] = useState('')
  const [editName, setEditName] = useState('')
  const [editNotes, setEditNotes] = useState('')
  const [busy, setBusy] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [playing, setPlaying] = useState<{ url: string; assetId: string } | null>(null)
  const close = useCallback(() => togglePanel(false), [togglePanel])
  useDialogFocusTrap(true, dialogRef, close)

  useEffect(() => {
    setEditName(selected?.name ?? '')
    setEditNotes(selected?.notes ?? '')
    setConfirmDelete(false)
    if (playing) {
      controller.revokeAssetURL(playing.url)
      setPlaying(null)
    }
    // The object URL cleanup is intentionally tied to selection changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedId])

  useEffect(() => () => {
    if (playing) controller.revokeAssetURL(playing.url)
  }, [controller, playing])

  async function run(action: () => Promise<void>) {
    if (busy) return
    setBusy(true)
    try { await action() } catch { /* controller publishes the operator-visible error */ }
    finally { setBusy(false) }
  }

  async function importFiles(files: File[]) {
    if (anyRecording || files.length === 0) return
    await run(() => controller.importFiles(files))
    if (fileInputRef.current) fileInputRef.current.value = ''
  }

  async function playAsset(session: BrowserRecordingSession, asset: BrowserRecordingAsset) {
    if (playing?.assetId === asset.id) return
    setBusy(true)
    try {
      if (playing) controller.revokeAssetURL(playing.url)
      const url = await controller.assetURL(session.id, asset)
      setPlaying({ url, assetId: asset.id })
    } catch { /* controller publishes error */ }
    finally { setBusy(false) }
  }

  async function downloadAsset(session: BrowserRecordingSession, asset: BrowserRecordingAsset) {
    setBusy(true)
    try {
      const url = await controller.assetURL(session.id, asset)
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = asset.name
      anchor.click()
      window.setTimeout(() => controller.revokeAssetURL(url), 30_000)
    } catch { /* controller publishes error */ }
    finally { setBusy(false) }
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/75 p-0 backdrop-blur-sm sm:p-4" onMouseDown={(event) => {
      if (event.target === event.currentTarget) close()
    }}>
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="recording-sessions-title"
        tabIndex={-1}
        className="mx-auto flex h-full max-w-[1500px] flex-col overflow-hidden border border-[#252936] bg-[#090b0f] shadow-2xl sm:rounded-xl"
      >
        <header className="flex shrink-0 items-center gap-4 border-b border-[#20232c] bg-[#0d0f14] px-4 py-3">
          <div>
            <h2 id="recording-sessions-title" className="text-base font-semibold text-white">Recording sessions</h2>
            <p className={`mt-0.5 text-[11px] ${error ? 'text-amber-300' : 'text-zinc-500'}`} role="status" aria-live="polite">
              {status}
            </p>
          </div>
          <div className="ml-auto flex items-center gap-2">
            {recording && <span className="rounded-full bg-red-500/15 px-2.5 py-1 text-[10px] font-semibold text-red-300">● RECORDING {formatDuration(recElapsed * 1_000)}</span>}
            <button onClick={() => void controller.recoverAndRefresh()} className="rounded-md bg-[#171a22] px-3 py-2 text-xs text-zinc-300 hover:bg-[#20242e]">Refresh</button>
            <button onClick={close} aria-label="Close recording sessions" className="rounded-md bg-[#171a22] px-3 py-2 text-xs text-zinc-300 hover:bg-[#20242e]">Close</button>
          </div>
        </header>

        <div className="flex min-h-0 flex-1 flex-col md:flex-row">
          <aside className="flex max-h-[43vh] w-full shrink-0 flex-col border-b border-[#20232c] bg-[#0c0e13] md:max-h-none md:w-[340px] md:border-b-0 md:border-r">
            <div className="space-y-2 border-b border-[#20232c] p-3">
              <label className="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500" htmlFor="new-session-name">Next capture</label>
              <input
                id="new-session-name"
                value={newName}
                onChange={(event) => setNewName(event.target.value)}
                maxLength={120}
                placeholder="Session name (optional)"
                className="w-full rounded-md border border-[#292d39] bg-[#11141a] px-3 py-2 text-xs text-zinc-200 placeholder:text-zinc-600"
              />
              <div className="grid grid-cols-2 gap-2">
                <button
                  disabled={!engineReady || anyRecording || busy}
                  onClick={() => void run(async () => {
                    await controller.start(newName)
                    setNewName('')
                  })}
                  className="rounded-md bg-red-600 px-3 py-2 text-xs font-semibold text-white hover:bg-red-500 disabled:cursor-not-allowed disabled:opacity-35"
                >
                  ● New session
                </button>
                <button
                  disabled={anyRecording || busy}
                  onClick={() => fileInputRef.current?.click()}
                  className="rounded-md bg-[#1a1e27] px-3 py-2 text-xs font-semibold text-cyan-300 hover:bg-[#232833] disabled:opacity-35"
                >
                  Import audio
                </button>
                <input
                  ref={fileInputRef}
                  hidden
                  type="file"
                  accept="audio/*,.wav,.wave,.aif,.aiff,.caf,.m4a,.mp3,.flac,.webm,.ogg,.opus"
                  multiple
                  onChange={(event) => void importFiles(Array.from(event.target.files ?? []))}
                />
              </div>
              {!engineReady && <p className="text-[10px] leading-relaxed text-zinc-600">Start Synthetic Stage or Live Microphone to capture. Review and import remain available while idle.</p>}
              {anyRecording && <p className="text-[10px] leading-relaxed text-amber-300/80">Imports are paused during live capture to protect recording storage bandwidth.</p>}
            </div>

            <div
              className="rack min-h-0 flex-1 overflow-y-auto p-2"
              onDragOver={(event) => { if (!anyRecording) event.preventDefault() }}
              onDrop={(event) => {
                if (anyRecording) return
                event.preventDefault()
                void importFiles(Array.from(event.dataTransfer.files))
              }}
            >
              {sessions.length === 0 ? (
                <div className="px-5 py-10 text-center">
                  <div className="text-3xl text-zinc-700">◉</div>
                  <p className="mt-3 text-sm font-medium text-zinc-300">No sessions yet</p>
                  <p className="mt-1 text-[11px] leading-relaxed text-zinc-600">Record a program or drop existing audio files here. Browser captures persist across reloads.</p>
                </div>
              ) : sessions.map((session) => (
                <button
                  key={session.id}
                  onClick={() => selectSession(session.id)}
                  className={`mb-1.5 flex w-full items-start gap-2.5 rounded-lg border p-3 text-left transition ${selectedId === session.id ? 'border-cyan-500/45 bg-cyan-500/10' : 'border-[#20242d] bg-[#111319] hover:border-[#303542]'}`}
                >
                  <span className={`mt-1 h-2 w-2 shrink-0 rounded-full ${statusDot(session.status)}`} aria-hidden="true" />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-xs font-semibold text-zinc-200">{session.name}</span>
                    <span className="mt-1 block truncate text-[10px] text-zinc-500">{formatDate(session.createdAtMs)} · {session.assets.length} file{session.assets.length === 1 ? '' : 's'} · {formatBytes(session.byteCount)}</span>
                  </span>
                </button>
              ))}
            </div>
          </aside>

          <main className="rack min-h-0 min-w-0 flex-1 overflow-y-auto">
            {selected ? (
              <div className="mx-auto max-w-5xl space-y-5 p-4 sm:p-6">
                <div className="flex flex-col gap-4 sm:flex-row sm:items-start">
                  <div className="min-w-0 flex-1">
                    <div className={`text-[10px] font-bold uppercase tracking-widest ${statusText(selected.status)}`}>{statusLabel(selected.status)}</div>
                    <h3 className="mt-1 truncate text-2xl font-semibold text-white">{selected.name}</h3>
                    <p className="mt-1 text-xs text-zinc-500">{selected.origin === 'browserCapture' ? 'Browser program capture' : 'Imported audio'} · {formatDate(selected.createdAtMs)} · {formatDuration(selected.durationMs)} · {formatBytes(selected.byteCount)}</p>
                  </div>
                  {selectedIsLocalRecording && (
                    <button onClick={() => void run(() => controller.stop())} disabled={busy} className="rounded-md bg-red-600 px-4 py-2 text-xs font-semibold text-white hover:bg-red-500 disabled:opacity-40">■ Stop & finalize</button>
                  )}
                </div>

                {(selected.status === 'interrupted' || selected.status === 'needsAttention') && (
                  <div className="rounded-lg border border-amber-500/25 bg-amber-500/8 p-4">
                    <div className="text-xs font-semibold text-amber-200">{selected.status === 'interrupted' ? 'Recording was interrupted' : 'Session needs attention'}</div>
                    <p className="mt-1 text-[11px] leading-relaxed text-amber-100/70">{selected.error ?? 'The recording did not finalize cleanly.'} Saved chunks are kept. Continuing always creates a new session, so recovered audio is never overwritten.</p>
                  </div>
                )}

                {selected.status === 'recording' && !selectedIsLocalRecording && (
                  <div className="rounded-lg border border-cyan-500/25 bg-cyan-500/8 p-4">
                    <div className="text-xs font-semibold text-cyan-200">Recording in another tab</div>
                    <p className="mt-1 text-[11px] leading-relaxed text-cyan-100/70">That tab owns the recorder and finalization controls. If it closed unexpectedly, wait for the lease to expire and choose Refresh to recover the saved chunks.</p>
                  </div>
                )}

                <div className="flex flex-wrap gap-2">
                  {selected.status !== 'recording' && (
                    <button
                      disabled={!engineReady || anyRecording || busy}
                      onClick={() => void run(() => controller.continueSession(selected.id))}
                      className="rounded-md bg-[#1a1e27] px-3 py-2 text-xs text-red-300 hover:bg-[#232833] disabled:opacity-35"
                    >
                      ● Continue as new capture
                    </button>
                  )}
                  <button
                    disabled={anyRecording || selected.status === 'recording' || busy}
                    onClick={() => setConfirmDelete(true)}
                    className="rounded-md bg-[#1a1e27] px-3 py-2 text-xs text-zinc-400 hover:bg-red-500/15 hover:text-red-300 disabled:opacity-35"
                  >
                    Delete from browser
                  </button>
                </div>

                {confirmDelete && (
                  <div className="flex flex-col gap-3 rounded-lg border border-red-500/30 bg-red-500/8 p-4 sm:flex-row sm:items-center">
                    <p className="flex-1 text-xs leading-relaxed text-red-100/80">Delete this session and all of its stored audio chunks from this browser? This cannot be undone. Download anything you need first.</p>
                    <button onClick={() => setConfirmDelete(false)} className="rounded-md bg-[#222630] px-3 py-2 text-xs">Cancel</button>
                    <button onClick={() => void run(() => controller.deleteSession(selected.id))} className="rounded-md bg-red-600 px-3 py-2 text-xs font-semibold text-white">Delete session</button>
                  </div>
                )}

                <section className="rounded-lg border border-[#232733] bg-[#101218] p-4">
                  <h4 className="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">Session details</h4>
                  <div className="mt-3 grid gap-3">
                    <input value={editName} onChange={(event) => setEditName(event.target.value)} maxLength={120} disabled={selected.status === 'recording'} className="rounded-md border border-[#292d39] bg-[#0b0d12] px-3 py-2 text-xs disabled:opacity-50" aria-label="Session name" />
                    <textarea value={editNotes} onChange={(event) => setEditNotes(event.target.value)} maxLength={2_000} rows={3} disabled={selected.status === 'recording'} placeholder="Review notes, speakers, incidents, or follow-up…" className="resize-y rounded-md border border-[#292d39] bg-[#0b0d12] px-3 py-2 text-xs placeholder:text-zinc-600 disabled:opacity-50" aria-label="Session notes" />
                    <button disabled={selected.status === 'recording' || busy} onClick={() => void run(() => controller.updateSession(selected.id, editName, editNotes))} className="w-fit rounded-md bg-cyan-600 px-3 py-2 text-xs font-semibold text-white hover:bg-cyan-500 disabled:opacity-35">Save details</button>
                  </div>
                </section>

                <section className="overflow-hidden rounded-lg border border-[#232733] bg-[#101218]">
                  <div className="border-b border-[#232733] px-4 py-3">
                    <h4 className="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">Recorded files</h4>
                  </div>
                  {selected.assets.length === 0 ? (
                    <p className="p-5 text-xs text-zinc-500">{selected.status === 'recording' ? 'Waiting for the first one-second recovery chunk…' : 'No playable audio payload was saved.'}</p>
                  ) : selected.assets.map((asset) => (
                    <div key={asset.id} className="border-b border-[#20232c] p-4 last:border-b-0">
                      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
                        <div className="min-w-0 flex-1">
                          <div className="truncate text-xs font-medium text-zinc-200">{asset.name}</div>
                          <div className="mt-1 text-[10px] text-zinc-500">{asset.kind === 'program' ? 'PROGRAM CAPTURE' : 'IMPORTED AUDIO'} · {asset.mimeType || 'audio'} · {formatBytes(asset.byteCount)}</div>
                        </div>
                        <div className="flex gap-2">
                          <button disabled={busy || asset.byteCount === 0} onClick={() => void playAsset(selected, asset)} className="rounded-md bg-[#1b1f28] px-3 py-2 text-[11px] text-cyan-300 hover:bg-[#252a35] disabled:opacity-35">Play</button>
                          <button disabled={busy || asset.byteCount === 0} onClick={() => void downloadAsset(selected, asset)} className="rounded-md bg-[#1b1f28] px-3 py-2 text-[11px] text-zinc-300 hover:bg-[#252a35] disabled:opacity-35">Download</button>
                        </div>
                      </div>
                      {playing?.assetId === asset.id && (
                        <audio
                          className="mt-3 w-full"
                          controls
                          autoPlay
                          src={playing.url}
                          onEnded={() => {
                            controller.revokeAssetURL(playing.url)
                            setPlaying(null)
                          }}
                          onError={() => {
                            controller.reportPlaybackFailure(asset.name)
                            controller.revokeAssetURL(playing.url)
                            setPlaying(null)
                          }}
                        />
                      )}
                    </div>
                  ))}
                </section>

                <p className="text-[10px] leading-relaxed text-zinc-600">Browser sessions store program audio in this browser profile using IndexedDB. One-second chunks limit crash loss, but they are not a substitute for the native app’s 64-input multitrack WAV capture. Export important browser recordings before clearing site data or moving to another machine.</p>
              </div>
            ) : (
              <div className="flex h-full min-h-[300px] items-center justify-center p-8 text-center">
                <div>
                  <div className="text-4xl text-zinc-700">◉</div>
                  <h3 className="mt-4 text-sm font-semibold text-zinc-300">Choose a recording session</h3>
                  <p className="mt-1 text-xs text-zinc-600">Play, download, rename, annotate, continue, or remove a saved session.</p>
                </div>
              </div>
            )}
          </main>
        </div>
      </div>
    </div>
  )
}

function statusDot(status: BrowserSessionStatus): string {
  if (status === 'recording') return 'bg-red-400'
  if (status === 'ready') return 'bg-emerald-400'
  return 'bg-amber-400'
}

function statusText(status: BrowserSessionStatus): string {
  if (status === 'recording') return 'text-red-300'
  if (status === 'ready') return 'text-emerald-300'
  return 'text-amber-300'
}

function statusLabel(status: BrowserSessionStatus): string {
  if (status === 'needsAttention') return 'Needs attention'
  return status.charAt(0).toUpperCase() + status.slice(1)
}

function formatDate(timestamp: number): string {
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(timestamp)
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  const power = Math.min(Math.floor(Math.log(bytes) / Math.log(1_000)), units.length - 1)
  return `${(bytes / 1_000 ** power).toFixed(power === 0 ? 0 : 1)} ${units[power]}`
}

function formatDuration(milliseconds: number): string {
  const total = Math.max(0, Math.round(milliseconds / 1_000))
  const hours = Math.floor(total / 3_600)
  const minutes = Math.floor((total % 3_600) / 60)
  const seconds = total % 60
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
    : `${minutes}:${String(seconds).padStart(2, '0')}`
}
