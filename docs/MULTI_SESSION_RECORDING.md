# Multi-session recording library

AutoMix treats recordings as durable, independent sessions instead of a single
temporary recording URL. The session library is available while the engine is idle,
so an operator can review, import, annotate, export, or prepare recorded work without
opening a live route.

"Multi-session" means many saved services, rehearsals, continuations, and imported
recordings in one library. Only one live recorder may own an audio engine at a time.
Starting competing writers against the same realtime graph or storage volume is
intentionally rejected.

## Native and browser capabilities

| Capability | AutoMix Native | Browser proof |
| --- | --- | --- |
| Live capture | Raw physical inputs plus final program L/R | Final browser program only |
| Persistence | Session folders under `~/Library/Application Support/AutoMix Native/Continuous Recordings` | IndexedDB in the current browser profile and origin |
| Recovery unit | Checkpointed 60-second float-WAV segments | Approximately one-second `MediaRecorder` chunks |
| Existing files | Copies supported audio into a managed session | Copies supported audio blobs into IndexedDB |
| Review | Derived program preview, per-file playback for imported/derived audio, Finder reveal | Per-file playback and download |
| Continue | Always creates a new linked session folder | Always creates a new linked browser session |
| Remove | Moves the complete session folder to macOS Trash | Explicitly deletes metadata and audio chunks after confirmation |
| Offline replay | Writes a versioned replay request for native multitrack segments | Not available; browser recordings have no raw inputs |

The browser version is useful for demos, quick program captures, review, and import.
It is not a substitute for the native 64-input forensic capture and cannot recreate a
new autonomous mix from program-only audio.

## Operator workflow

### Record another live session

1. Open **Sessions** / **Recording sessions**.
2. Optionally enter a name and operator note.
3. Start the audio engine, then choose **New live session**. The existing capacity and
   soundcheck mutual-exclusion gates still apply.
4. Confirm the session says **Recording** and its byte/frame/chunk count advances.
5. Choose **Stop recording** / **Stop & finalize** before quitting or removing storage.

The recorder never appends to or overwrites an earlier session. **Continue as new
capture** carries the earlier session ID as lineage and creates a new destination.

### Work from recordings

- Rename a completed session and add review notes without renaming its storage folder.
- Play the native program preview. It is generated from the final two channels of all
  compatible capture segments on a background task; raw multitrack files are not
  changed. Imported and replay audio can be played per file.
- Reveal a native session in Finder to copy it into a DAW or archive workflow. Keep
  the manifest, completion marker, and every segment together.
- Download browser assets before clearing site data or changing browser profiles.
- Import existing audio. Both apps copy it into managed storage; the source is left
  untouched. Native import validates with AVFoundation before copying. Browser import
  validates the audio MIME type or extension and reports playback failures from the
  browser decoder.

### Replay a native multitrack session

1. On a completed native capture, choose **Prepare replay**. This writes
   `Derived/Replay Request.json` with the exact ordered segments, scene, role map, and
   stereo pairs captured at session start.
2. Build the deterministic replay evaluator as described in
   [`REPLAY_EVALUATION.md`](REPLAY_EVALUATION.md).
3. Run:

   ```bash
   scripts/run-recording-session-replay.py \
     "/path/to/session/Derived/Replay Request.json" \
     --replay-binary /path/to/automix_replay
   ```

Each invocation creates a new `Derived/Replay Runs/run-…` directory containing a
program WAV, metrics JSON, and decision JSONL for every segment plus an aggregate
`replay-index.json`. Sources and earlier runs are never overwritten. Exit status is
zero only when every evaluator invocation succeeds and passes its electrical safety
checks; status 1 means a safety check failed, and status 2 means input or processing
failed. Partial output and stderr remain indexed for diagnosis.

The current evaluator renders each 60-second segment independently, so its control
state restarts at segment boundaries. These outputs are appropriate for listening,
fault isolation, and segment-level regression. They must not be presented as a
continuous full-service control-state evaluation. A promotion decision still uses
representative corpus comparisons and supervised shadow-mode validation.

## Session states

- **Recording** — the sole active writer owns the session. Rename, preview, import,
  replay, continuation, and removal actions that could contend with it are locked.
- **Ready** — capture finalized cleanly, assets are readable, and native dropped-frame
  count is zero.
- **Interrupted** — no clean completion record was found, but saved audio remains.
  Continue into a new session; never repair by recording over the old files.
- **Needs attention** — audio is missing/unreadable, a browser capture saved no data,
  storage failed, or native capture reports dropped frames. Files are retained for
  investigation, but the session is not a trustworthy replay source.

## Edge-case behavior

### Crash, forced quit, power loss, or closed tab

- Native completed segments stay intact. The open WAV header is checkpointed about
  once per second; payload after its last checkpoint may need repair. With no clean
  completion marker, the library recovers the folder as **Interrupted**.
- Browser chunks already committed to IndexedDB remain. On next load, a stale
  **Recording** session becomes **Interrupted**. Up to the current approximately
  one-second chunk can be lost.
- A continuation always gets a new ID and folder/record set.

### Storage exhaustion and slow storage

- Native capture is gated by planned uncompressed size plus reserve and rechecks free
  space every 30 seconds. A slow disk drops recorder frames and keeps the live mix
  running; any drop marks the session **Needs attention**.
- Native imports reserve 1 GB after the copy. A partial managed import is removed if
  the copy fails; source files are never removed.
- Browser imports require the reported quota to retain a 100 MB reserve. Capture
  cannot predict compressed `MediaRecorder` size, so an IndexedDB quota/write error
  stops and finalizes the session as **Needs attention**.

### Multiple windows, tabs, and engines

- Native has one in-process Core Audio recorder and rejects a second capture or a
  simultaneous soundcheck.
- Browser uses the Web Locks API when available so one origin has one recorder owner
  across tabs. Older browsers use a renewable 10-second local-storage lease; a stale
  lease expires after a crashed tab.

### Missing, moved, changed, or corrupt files

- Native rescans the managed folder on launch/refresh and validates each audio asset.
  Missing or unreadable assets surface as **Needs attention**; they are not silently
  skipped for replay.
- Program preview requires every native segment to have the same sample rate/channel
  layout and at least two channels. A mismatch fails without replacing a previous
  usable preview.
- If an entire native session folder is moved intact, the replay runner can recover
  stale absolute segment paths by basename from that session root. It never searches
  outside the session and refuses external output paths.
- Browser storage belongs to one browser origin/profile. Site-data clearing, private
  browsing eviction, a different hostname/port policy, or another machine does not
  carry the library; export important assets first.

### Large and unusual files

- Native 64-input/96 kHz capture is roughly 91.2 GB/hour. Keep it on a proven local
  SSD and archive with checksums. Preview streams through segments rather than loading
  the complete session into memory.
- Browser playback/download assembles an asset Blob from stored chunks. Very long
  captures may require substantial browser memory during export; use native capture
  for production-length multitrack services.
- Browser acceptance by extension does not guarantee that the current browser can
  decode every CAF/AIFF/FLAC variant. A decode failure does not delete the import.
- The C++ replay reader accepts RIFF/WAVE data chunks above 1 GiB so one 66-channel,
  96 kHz, 60-second native segment is valid. It still materializes a segment in
  memory, and RIFF output is limited to 4 GiB; the session runner keeps output split
  per capture segment.

### Deletion and retention

- Native operator removal uses macOS Trash. Automatic retention is off by default and
  may move only cleanly completed sessions older than the configured age.
- Browser deletion is not recoverable from the app. It requires explicit confirmation
  and is blocked for the active session.
- Derived previews and replay runs live inside the native session folder, so moving a
  session to Trash or archiving it moves those artifacts with it.

## Validation coverage

Native tests cover 66-channel session discovery, clean/interrupted transitions,
copy-on-import, program-pair extraction across segments, corruption, and dropped
frames. Browser type/build checks cover the recorder API integration; the UI has also
been exercised for record/reload/reopen/import/delete and a 390 px mobile layout.
Replay-runner tests cover multiple parts, non-destructive reruns, moved folders,
safety-failure propagation, and output-path containment.
