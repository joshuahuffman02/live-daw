import type { InputMode } from '../audio/engine'

export default function StartScreen({
  onStart, booting, error,
}: {
  onStart: (m: InputMode) => void
  booting: boolean
  error: string | null
}) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-[#0a0b0e] p-6 text-zinc-200">
      <div className="w-full max-w-2xl">
        <div className="mb-2 flex items-center gap-2 text-xs font-medium uppercase tracking-widest text-cyan-400/80">
          <span className="rec-dot inline-block h-2 w-2 rounded-full bg-red-500" />
          Autonomous Broadcast Mixer · proof-of-concept
        </div>
        <h1 className="text-3xl font-semibold tracking-tight text-white">AutoMix</h1>
        <p className="mt-3 max-w-xl text-sm leading-relaxed text-zinc-400">
          A runnable embodiment of the spec: deterministic per-sample DSP on the audio
          thread (gain-sharing automix, BS.1770 loudness + true-peak limiter, gate) with
          a control-rate <span className="text-cyan-400">brain</span> that classifies
          channels, auto-EQs toward target curves, rides levels to per-scene targets, and
          de-esses — with manual override, FREEZE, and a hard SAFE bypass. No ML in the
          audio path.
        </p>

        <div className="mt-8 grid gap-4 sm:grid-cols-2">
          <button
            disabled={booting}
            onClick={() => onStart('synthetic')}
            className="group rounded-xl border border-[#232733] bg-[#121419] p-5 text-left transition hover:border-cyan-500/50 hover:bg-[#161922] disabled:opacity-50"
          >
            <div className="text-base font-medium text-white">Synthetic Stage</div>
            <div className="mt-1 text-xs leading-relaxed text-zinc-400">
              9 simulated church-stage channels (2 speech mics, lead/BGV vocals,
              acoustic, electric, bass, kick, keys). Watch the classifier, automix,
              auto-EQ and loudness react. No files needed.
            </div>
            <div className="mt-3 text-xs font-medium text-cyan-400 group-hover:underline">Start →</div>
          </button>

          <button
            disabled={booting}
            onClick={() => onStart('mic')}
            className="group rounded-xl border border-[#232733] bg-[#121419] p-5 text-left transition hover:border-cyan-500/50 hover:bg-[#161922] disabled:opacity-50"
          >
            <div className="text-base font-medium text-white">Live Microphone</div>
            <div className="mt-1 text-xs leading-relaxed text-zinc-400">
              Feed it your own voice. Hear the speech automix, auto-EQ, compression,
              de-essing and the true-peak loudness limiter work on real audio.
              <span className="text-amber-400/80"> Use headphones to avoid feedback.</span>
            </div>
            <div className="mt-3 text-xs font-medium text-cyan-400 group-hover:underline">Grant mic & start →</div>
          </button>
        </div>

        {booting && <div className="mt-6 text-sm text-zinc-400">Booting audio engine & worklets…</div>}
        {error && (
          <div className="mt-6 rounded-lg border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-300">
            {error}
          </div>
        )}

        <p className="mt-8 text-xs leading-relaxed text-zinc-600">
          This is the product/UX proof — not the shippable Dante appliance (that's the
          C++/JUCE target in <span className="font-mono">SPEC.md</span>). The architecture,
          DSP behavior and supervisory UI here map 1:1 to that build.
        </p>
      </div>
    </div>
  )
}
