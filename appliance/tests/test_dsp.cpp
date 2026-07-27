// test_dsp.cpp — standalone correctness tests for the pure-C++ DSP core.
// No JUCE, no audio device: compile with `clang++ -std=c++17` and run. These assert
// the invariants that matter for a broadcast engine — the limiter never exceeds its
// ceiling, loudness scales correctly, the automixer's gains sum toward unity, etc.
#include "../dsp/SVF.h"
#include "../dsp/Loudness.h"
#include "../dsp/Limiter.h"
#include "../dsp/Automixer.h"
#include "../dsp/Compressor.h"
#include "../dsp/Gate.h"
#include "../dsp/Engine.h"
#include "../dsp/BeatTracker.h"
#include "../dsp/OnsetDetector.h"
#include "../dsp/Reverb.h"
#include "../dsp/TempoDelay.h"
#include "../src/BrainThread.h"

#include <atomic>
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <new>
#include <vector>
#include <random>
#include <thread>

using namespace bdsp;

static int g_fail = 0, g_pass = 0;
static std::atomic<int> g_allocationGuard{0};
static std::atomic<int> g_allocationsWhileGuarded{0};

void* operator new(std::size_t size) {
    if (g_allocationGuard.load(std::memory_order_relaxed) > 0) {
        g_allocationsWhileGuarded.fetch_add(1, std::memory_order_relaxed);
    }
    if (void* p = std::malloc(size)) return p;
    throw std::bad_alloc();
}

void* operator new[](std::size_t size) {
    if (g_allocationGuard.load(std::memory_order_relaxed) > 0) {
        g_allocationsWhileGuarded.fetch_add(1, std::memory_order_relaxed);
    }
    if (void* p = std::malloc(size)) return p;
    throw std::bad_alloc();
}

void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }

struct AllocationGuard {
    AllocationGuard() {
        g_allocationsWhileGuarded.store(0, std::memory_order_relaxed);
        g_allocationGuard.fetch_add(1, std::memory_order_relaxed);
    }
    ~AllocationGuard() {
        g_allocationGuard.fetch_sub(1, std::memory_order_relaxed);
    }
};

#define CHECK(cond, msg) do { \
    if (cond) { ++g_pass; } \
    else { ++g_fail; std::printf("  FAIL: %s\n", msg); } \
} while (0)

static const double FS = 48000.0;

static void testDefaultSampleRate() {
    std::printf("DSP defaults (HD96/Dante sample rate)\n");
    CHECK(kDefaultSampleRate == 96000.0, "DSP fallback sample rate defaults to 96 kHz");
}

static double rms(const std::vector<float>& v, int start = 0) {
    double s = 0; int n = 0;
    for (int i = start; i < (int)v.size(); ++i) { s += (double)v[i] * v[i]; ++n; }
    return std::sqrt(s / std::max(1, n));
}

// ---- SVF -------------------------------------------------------------------
static void testSVF() {
    std::printf("SVF (TPT state-variable filter)\n");
    auto runSine = [](SVF& f, double hz, int n) {
        std::vector<float> out(n);
        double ph = 0, inc = 2 * M_PI * hz / FS;
        for (int i = 0; i < n; ++i) { out[i] = f.process((float)std::sin(ph)); ph += inc; }
        return out;
    };
    SVF lp; lp.reset(FS); lp.set(SVF::LowPass, 500.0, 0.707);
    auto low = runSine(lp, 100.0, 9600);
    SVF lp2; lp2.reset(FS); lp2.set(SVF::LowPass, 500.0, 0.707);
    auto high = runSine(lp2, 8000.0, 9600);
    CHECK(rms(low, 4800) > rms(high, 4800) * 5.0, "lowpass passes 100Hz, attenuates 8kHz");

    SVF bell; bell.reset(FS); bell.set(SVF::Bell, 1000.0, 1.0, 0.0); // 0 dB = transparent
    auto same = runSine(bell, 1000.0, 4800);
    CHECK(std::fabs(rms(same, 2400) - 0.7071) < 0.05, "0 dB bell is transparent");
}

// ---- Loudness --------------------------------------------------------------
static double measureLufs(float amp, double fs = FS) {
    Loudness L; L.reset(fs);
    double ph = 0, inc = 2 * M_PI * 1000.0 / fs;
    for (int i = 0; i < (int)(2.0 * fs); ++i) {
        const float x = amp * (float)std::sin(ph); ph += inc;
        L.process(x, x);
    }
    return L.integrated();
}
static void testLoudness() {
    std::printf("Loudness (BS.1770 integrated LUFS)\n");
    const double l1 = measureLufs(0.1f);
    const double l2 = measureLufs(0.2f);
    CHECK(std::isfinite(l1) && l1 > -60 && l1 < 0, "integrated LUFS is finite & sane");
    CHECK(std::fabs((l2 - l1) - 6.02) < 0.5, "doubling amplitude raises loudness ~6 dB");
    const double h1 = measureLufs(0.1f, 96000.0);
    const double h2 = measureLufs(0.2f, 96000.0);
    CHECK(std::isfinite(h1) && std::fabs((h2 - h1) - 6.02) < 0.5, "96 kHz K-weighting remains sample-rate correct");
}

// ---- Limiter ---------------------------------------------------------------
static void testLimiter() {
    std::printf("Limiter (true-peak look-ahead brickwall)\n");
    Limiter lim; lim.reset(FS, -1.0f); // ceiling -1 dBTP ~= 0.891 linear
    const float ceiling = std::pow(10.0f, -1.0f / 20.0f);
    double ph = 0, inc = 2 * M_PI * 1000.0 / FS;
    float maxOut = 0;
    for (int i = 0; i < (int)(0.5 * FS); ++i) {
        const float x = 1.0f * (float)std::sin(ph); ph += inc; // 0 dBFS
        float oL, oR; lim.process(x, x, oL, oR);
        maxOut = std::max(maxOut, std::max(std::fabs(oL), std::fabs(oR)));
    }
    CHECK(maxOut <= ceiling + 1e-3f, "output never exceeds the ceiling on a 0 dBFS sine");

    Limiter lim2; lim2.reset(FS, -1.0f);
    ph = 0; float maxQuiet = 0;
    for (int i = 0; i < (int)(0.5 * FS); ++i) {
        const float x = 0.1f * (float)std::sin(ph); ph += inc; // -20 dBFS, below ceiling
        float oL, oR; lim2.process(x, x, oL, oR);
        if (i > FS * 0.1) maxQuiet = std::max(maxQuiet, std::fabs(oL));
    }
    CHECK(std::fabs(lim2.gainReductionDb()) < 0.1f, "transparent below the ceiling (no GR)");
    CHECK(std::fabs(maxQuiet - 0.1f) < 0.02f, "quiet signal passes unchanged");
}

// ---- Automixer -------------------------------------------------------------
static void runAutomix(Automixer& am, float a0, float a1, int blocks, int frames) {
    std::vector<float> b0(frames), b1(frames), out(frames);
    const float* ins[2] = {b0.data(), b1.data()};
    double ph0 = 0, ph1 = 0, inc = 2 * M_PI * 300.0 / FS;
    for (int b = 0; b < blocks; ++b) {
        for (int s = 0; s < frames; ++s) {
            b0[s] = a0 * (float)std::sin(ph0); ph0 += inc;
            b1[s] = a1 * (float)std::sin(ph1); ph1 += inc * 1.3;
        }
        am.process(ins, out.data(), frames);
    }
}
static void testAutomix() {
    std::printf("Automixer (Dugan gain-sharing)\n");
    Automixer am; am.reset(FS, 2);
    runAutomix(am, 0.5f, 0.0f, 200, 128); // only mic 0 talking
    CHECK(am.gain(0) > 0.8f, "talking mic gets ~unity gain");
    CHECK(am.gain(1) < 0.2f, "silent mic ducks down");

    Automixer am2; am2.reset(FS, 2);
    runAutomix(am2, 0.4f, 0.4f, 200, 128); // both equal
    const float sum = am2.gain(0) + am2.gain(1);
    CHECK(std::fabs(sum - 1.0f) < 0.15f, "gains sum toward unity (constant noise floor)");
    CHECK(am2.gain(0) > 0.3f && am2.gain(1) > 0.3f, "two equal mics share evenly");

    // Behavior at the native 96 kHz / 512-frame operating point. The detector is
    // block-rate, so this catches accidentally applying per-sample time constants
    // only once per callback (which makes speech acquisition take seconds).
    Automixer fast; fast.reset(96000.0, 2);
    const int nativeFrames = 512;
    std::vector<float> talk(nativeFrames, 0.35f);
    std::vector<float> quiet(nativeFrames, 0.0f);
    std::vector<float> out(nativeFrames, 0.0f);
    const float* firstSpeaker[2] = {talk.data(), quiet.data()};
    for (int b = 0; b < 8; ++b) fast.process(firstSpeaker, out.data(), nativeFrames);
    CHECK(fast.gain(0) > 0.8f && fast.gain(1) < 0.2f,
          "96 kHz speech mic acquires dominance within about 43 ms");

    const float* secondSpeaker[2] = {quiet.data(), talk.data()};
    for (int b = 0; b < 24; ++b) fast.process(secondSpeaker, out.data(), nativeFrames);
    CHECK(fast.gain(1) > 0.75f && fast.gain(0) < 0.25f,
          "96 kHz speech handoff follows a new talker within about 130 ms");

    {
        AllocationGuard guard;
        fast.process(secondSpeaker, out.data(), nativeFrames);
    }
    CHECK(g_allocationsWhileGuarded.load(std::memory_order_relaxed) == 0,
          "automixer detector timing remains allocation-free");
}

// ---- Compressor ------------------------------------------------------------
static void testCompressor() {
    std::printf("Compressor (feed-forward, soft-knee)\n");
    Compressor c; c.reset(FS); c.setParams(-20.0f, 4.0f, 0.005f, 0.1f, 0.0f, 0.0f);
    double ph = 0, inc = 2 * M_PI * 500.0 / FS;
    std::vector<float> in, out;
    for (int i = 0; i < (int)(0.5 * FS); ++i) {
        const float x = 0.5f * (float)std::sin(ph); ph += inc; // ~ -6 dBFS, above -20
        in.push_back(x); out.push_back(c.process(x));
    }
    CHECK(c.gainReductionDb() < -1.0f, "compresses signal above threshold (negative dB convention)");
    CHECK(rms(out, (int)(0.2 * FS)) < rms(in, (int)(0.2 * FS)), "output quieter than input");

    Compressor c2; c2.reset(FS); c2.setParams(-20.0f, 4.0f, 0.005f, 0.1f, 0.0f, 0.0f);
    ph = 0;
    for (int i = 0; i < (int)(0.3 * FS); ++i) { const float x = 0.01f * (float)std::sin(ph); ph += inc; c2.process(x); }
    CHECK(std::fabs(c2.gainReductionDb()) < 0.5f, "transparent below threshold");
}

// ---- Gate ------------------------------------------------------------------
static void testGate() {
    std::printf("Gate / expander (hysteresis)\n");
    Gate g; g.reset(FS); g.setParams(true, -30.0f, 4.0f, 24.0f);
    double ph = 0, inc = 2 * M_PI * 400.0 / FS;
    std::vector<float> loudIn, loudOut;
    for (int i = 0; i < (int)(0.3 * FS); ++i) { const float x = 0.5f * (float)std::sin(ph); ph += inc; loudIn.push_back(x); loudOut.push_back(g.process(x)); }
    CHECK(g.isOpen(), "gate opens on loud signal");
    CHECK(rms(loudOut, (int)(0.1 * FS)) > rms(loudIn, (int)(0.1 * FS)) * 0.8, "passes loud signal");

    Gate g2; g2.reset(FS); g2.setParams(true, -30.0f, 4.0f, 24.0f);
    ph = 0; std::vector<float> qIn, qOut;
    for (int i = 0; i < (int)(0.3 * FS); ++i) { const float x = 0.005f * (float)std::sin(ph); ph += inc; qIn.push_back(x); qOut.push_back(g2.process(x)); }
    CHECK(rms(qOut, (int)(0.1 * FS)) < rms(qIn, (int)(0.1 * FS)) * 0.5, "attenuates quiet signal below threshold");
}

// ---- Engine smoke ----------------------------------------------------------
static void testEngine() {
    std::printf("Engine (full chain + SAFE bypass)\n");
    const int N = 4, frames = 256;
    Engine eng; eng.prepare(FS, frames, N);
    eng.setChannelConfig(0, BusId::Speech, true);
    eng.setChannelConfig(1, BusId::Speech, true);
    eng.setChannelConfig(2, BusId::Band, false);
    eng.setChannelConfig(3, BusId::Drums, false);
    for (int i = 0; i < N; ++i) { ChannelParams p; p.isSpeech = (i < 2); p.faderDb = -6; eng.setChannelParams(i, p); }
    MasterParams m; eng.setMasterParams(m);

    std::mt19937 rng(1); std::uniform_real_distribution<float> d(-0.3f, 0.3f);
    std::vector<std::vector<float>> in(N, std::vector<float>(frames));
    std::vector<float> oL(frames), oR(frames);
    std::vector<const float*> ptrs(N);
    const float ceiling = std::pow(10.0f, -1.0f / 20.0f);

    auto runBlocks = [&](int blocks) {
        bool finite = true; float mx = 0;
        for (int b = 0; b < blocks; ++b) {
            for (int i = 0; i < N; ++i) { for (int s = 0; s < frames; ++s) in[i][s] = d(rng); ptrs[i] = in[i].data(); }
            eng.process(ptrs.data(), N, oL.data(), oR.data(), frames);
            for (int s = 0; s < frames; ++s) {
                if (!std::isfinite(oL[s]) || !std::isfinite(oR[s])) finite = false;
                mx = std::max(mx, std::max(std::fabs(oL[s]), std::fabs(oR[s])));
            }
        }
        return std::make_pair(finite, mx);
    };

    auto [finite1, mx1] = runBlocks(200);
    CHECK(finite1, "processed output is finite");
    CHECK(mx1 <= ceiling + 1e-3f, "master output respects the true-peak ceiling");

    eng.setBypass(true);
    auto [finite2, mx2] = runBlocks(50);
    CHECK(finite2 && mx2 <= ceiling + 1e-3f, "SAFE bypass still flows audio under the ceiling");
    CHECK(std::isfinite(eng.integratedLufs()), "loudness meter produces a reading");
}

static void testEngine96kAndRouting() {
    std::printf("Engine (96 kHz, bus routing, pan, and SAFE raw sum)\n");
    const double fs = 96000.0;
    const int N = 2, frames = 512;
    Engine eng; eng.prepare(fs, frames, N);
    eng.setChannelConfig(0, BusId::Band, false);
    eng.setChannelConfig(1, BusId::Band, false);

    ChannelParams left; left.faderDb = 0.0f; left.pan = -1.0f; left.hpfHz = 20.0f; left.compRatio = 1.0f; left.reverbSendDb = -60.0f;
    ChannelParams right = left; right.pan = 1.0f;
    eng.setChannelParams(0, left);
    eng.setChannelParams(1, right);

    std::vector<std::vector<float>> in(N, std::vector<float>(frames, 0.0f));
    std::vector<float> oL(frames), oR(frames);
    std::vector<const float*> ptrs{in[0].data(), in[1].data()};

    auto runTone = [&](int activeChannel) {
        double ph = 0.0, inc = 2 * M_PI * 1000.0 / fs;
        for (int b = 0; b < 140; ++b) {
            for (int s = 0; s < frames; ++s) {
                const float x = 0.04f * (float)std::sin(ph);
                ph += inc;
                in[0][s] = activeChannel == 0 ? x : 0.0f;
                in[1][s] = activeChannel == 1 ? x : 0.0f;
            }
            eng.process(ptrs.data(), N, oL.data(), oR.data(), frames);
        }
        return std::make_pair(rms(oL, frames / 2), rms(oR, frames / 2));
    };

    auto [leftL, leftR] = runTone(0);
    CHECK(leftL > leftR * 5.0, "left-panned band source routes primarily left at 96 kHz");

    auto [rightL, rightR] = runTone(1);
    CHECK(rightR > rightL * 5.0, "right-panned band source routes primarily right at 96 kHz");

    eng.setBypass(true);
    for (int s = 0; s < frames; ++s) {
        in[0][s] = 0.05f;
        in[1][s] = -0.05f;
    }
    for (int b = 0; b < 20; ++b) eng.process(ptrs.data(), N, oL.data(), oR.data(), frames);
    CHECK(rms(oL) < 1e-5 && rms(oR) < 1e-5, "SAFE bypass uses raw mono sum before channel processing");
}

static void testEngineProcessNoAllocation() {
    std::printf("Engine (realtime no-allocation invariant)\n");
    const int N = 6, frames = 256;
    Engine eng; eng.prepare(96000.0, frames, N);
    for (int i = 0; i < N; ++i) {
        eng.setChannelConfig(i, i < 2 ? BusId::Speech : BusId::Band, i < 2);
        ChannelParams p; p.isSpeech = i < 2; p.faderDb = -6.0f; eng.setChannelParams(i, p);
    }

    std::vector<std::vector<float>> in(N, std::vector<float>(frames));
    std::vector<const float*> ptrs(N);
    std::vector<float> oL(frames), oR(frames);
    for (int i = 0; i < N; ++i) ptrs[i] = in[i].data();

    double ph = 0.0;
    {
        AllocationGuard guard;
        eng.setChannelConfig(2, BusId::Speech, true);
        for (int b = 0; b < 200; ++b) {
            for (int i = 0; i < N; ++i) {
                for (int s = 0; s < frames; ++s) {
                    in[i][s] = 0.03f * (float)std::sin(ph + i);
                    ph += 0.005;
                }
            }
            eng.process(ptrs.data(), N, oL.data(), oR.data(), frames);
        }
    }
    CHECK(g_allocationsWhileGuarded.load(std::memory_order_relaxed) == 0, "Engine::process performs no heap allocations after prepare");
    CHECK(g_allocationsWhileGuarded.load(std::memory_order_relaxed) == 0, "Engine::setChannelConfig performs no heap allocations after prepare");
}

static double renderEngineWithMasterLoudnessTrim(float trimDb, bool* shortTermReady = nullptr) {
    const int frames = 256;
    Engine eng;
    eng.prepare(FS, frames, 1);
    eng.setChannelConfig(0, BusId::Band, false);

    ChannelParams channel;
    channel.faderDb = 0.0f;
    channel.pan = 0.0f;
    channel.hpfHz = 20.0f;
    channel.compRatio = 1.0f;
    channel.reverbSendDb = -60.0f;
    eng.setChannelParams(0, channel);

    MasterParams master;
    master.glueRatio = 1.0f;
    master.loudnessTrimDb = trimDb;
    master.reverbReturnDb = -60.0f;
    eng.setMasterParams(master);

    std::vector<float> input(frames), outL(frames), outR(frames);
    std::vector<const float*> inputs{input.data()};
    double phase = 0.0;
    const double increment = 2.0 * M_PI * 1000.0 / FS;
    for (int block = 0; block < (int)(FS * 3.2 / frames); ++block) {
        for (int sample = 0; sample < frames; ++sample) {
            input[(size_t)sample] = 0.002f * (float)std::sin(phase);
            phase += increment;
        }
        eng.process(inputs.data(), 1, outL.data(), outR.data(), frames);
    }
    if (shortTermReady) *shortTermReady = eng.shortTermLoudnessReady();
    return rms(outL, frames / 2);
}

static void testEngineMasterLoudnessTrim() {
    std::printf("Engine (smoothed master loudness trim)\n");
    bool shortTermReady = false;
    const double baseline = renderEngineWithMasterLoudnessTrim(0.0f);
    const double raised = renderEngineWithMasterLoudnessTrim(6.0f, &shortTermReady);
    CHECK(shortTermReady, "short-term loudness readiness requires a complete 3-second window");
    CHECK(raised > baseline * 1.85, "+6 dB loudness trim approximately doubles low-level output");
    CHECK(raised < baseline * 2.15, "master loudness trim stays within its requested gain");
}

static void testBrainThreadControls() {
    std::printf("BrainThread (channel limits, role profiles, manual overrides)\n");
    bool threw = false;
    try {
        app::BrainThread tooMany;
        tooMany.configure(app::EngineSnapshot::kMaxCh + 1, 96000.0, {});
    } catch (const std::invalid_argument&) {
        threw = true;
    }
    CHECK(threw, "rejects channel counts beyond the 64-channel native/Dante guard");
    CHECK(app::profileFor(app::Cls::Speech).isSpeech, "speech role maps to speech bus behavior");
    CHECK(app::profileFor(app::Cls::Kick).bus == BusId::Drums, "kick role maps to drums bus");

    std::vector<app::Cls> roles{app::Cls::Speech, app::Cls::Bass, app::Cls::Kick};
    app::BrainThread brain;
    brain.configure((int)roles.size(), 96000.0, roles);

    ChannelParams manual; manual.faderDb = -18.0f; manual.pan = -0.5f;
    CHECK(brain.setManualChannelParams(1, manual, app::OverrideFader | app::OverridePan), "accepts manual override on valid channel");
    CHECK(!brain.setManualChannelParams(99, manual, app::OverrideFader), "rejects manual override on invalid channel");
    CHECK(brain.clearManualOverrides(1, app::OverridePan), "clears a manual override mask on valid channel");
    CHECK(!brain.clearManualOverrides(-1), "rejects clearing override on invalid channel");
    CHECK(brain.setAssignedClass(1, app::Cls::Speech), "accepts live source-role reassignment on valid channel");
    CHECK(!brain.setAssignedClass(99, app::Cls::Speech), "rejects live source-role reassignment on invalid channel");
    {
        AllocationGuard guard;
        brain.pushChannelMeasurement(0, -24.0f, -12.0f, -28.0f);
    }
    CHECK(g_allocationsWhileGuarded.load(std::memory_order_relaxed) == 0,
          "audio-to-brain channel measurement publish performs no heap allocations");

    Engine eng; eng.prepare(96000.0, 256, (int)roles.size());
    for (int i = 0; i < (int)roles.size(); ++i) {
        const auto p = app::profileFor(roles[(size_t)i]);
        eng.setChannelConfig(i, p.bus, p.isSpeech);
    }
    brain.setOperatorBypass(true);
    brain.start();
    std::this_thread::sleep_for(std::chrono::milliseconds(120));
    {
        AllocationGuard guard;
        for (int i = 0; i < 8; ++i) brain.applyTo(eng);
    }
    CHECK(g_allocationsWhileGuarded.load(std::memory_order_relaxed) == 0, "BrainThread::applyTo performs no heap allocations on the audio path");
    CHECK(!brain.watchdogBypassActive(), "watchdog SAFE stays inactive while the brain is ticking");
    brain.stop();

    std::vector<std::vector<float>> in(roles.size(), std::vector<float>(256, 0.01f));
    std::vector<const float*> ptrs{in[0].data(), in[1].data(), in[2].data()};
    std::vector<float> oL(256), oR(256);
    eng.process(ptrs.data(), (int)roles.size(), oL.data(), oR.data(), 256);
    CHECK(std::isfinite(oL.back()) && std::isfinite(oR.back()), "brain snapshot applies to engine without blocking the audio path");

    std::this_thread::sleep_for(std::chrono::milliseconds(650));
    brain.applyTo(eng);
    CHECK(brain.watchdogBypassActive(), "watchdog SAFE activates when the brain stops ticking");
}

static void testBrainMeasurementDrivenGainStaging() {
    std::printf("BrainThread (measurement-driven activity, gain staging, and level ride)\n");
    std::vector<app::Cls> roles{app::Cls::Speech, app::Cls::Unknown, app::Cls::Electric};
    app::BrainThread brain;
    brain.configure((int)roles.size(), 96000.0, roles);
    brain.setScene(app::Scene::Worship);

    // Known weak speech should be acquired and raised conservatively. The same
    // measurement on an unassigned channel must not trigger autonomous gain.
    brain.pushChannelMeasurement(0, -38.0f, -28.0f, -44.0f);
    brain.pushChannelMeasurement(1, -38.0f, -28.0f, -44.0f);
    // An idle instrument channel teaches the floor without becoming active.
    brain.pushChannelMeasurement(2, -72.0f, -65.0f, -100.0f);

    brain.start();
    std::this_thread::sleep_for(std::chrono::milliseconds(1100));
    brain.stop();

    CHECK(brain.channelActive(0), "weak but useful assigned speech is detected as active");
    CHECK(brain.currentAutoTrimDb(0) >= 4.0f && brain.currentAutoTrimDb(0) <= 6.5f,
          "assigned weak speech gain rises at the bounded 5 dB/s rate");
    CHECK(brain.currentAutoFaderDb(0) > -4.0f,
          "active speech level ride moves toward its role target");
    CHECK(std::fabs(brain.currentAutoTrimDb(1)) < 0.01f,
          "unknown channel is measured but never autonomously gain-staged");
    CHECK(!brain.channelActive(2), "idle channel remains inactive");
    CHECK(brain.currentNoiseFloorDb(2) < -68.0f,
          "idle measurement teaches a lower per-channel noise floor");
}

static void testBrainMasterLoudnessControl() {
    std::printf("BrainThread (slow master loudness normalization)\n");
    app::BrainThread brain;
    brain.configure(0, 96000.0, {});
    brain.setScene(app::Scene::Sermon);
    {
        AllocationGuard guard;
        brain.pushMasterMeasurement(-24.0f, -24.0f, 0.0f, true);
    }
    CHECK(g_allocationsWhileGuarded.load(std::memory_order_relaxed) == 0,
          "audio-to-brain master measurement publish performs no heap allocations");

    brain.start();
    std::this_thread::sleep_for(std::chrono::milliseconds(1100));
    const float raised = brain.currentAutoLoudnessTrimDb();
    CHECK(raised >= 0.8f && raised <= 1.3f,
          "low program loudness raises master trim at no more than 1 dB/s");

    brain.pushMasterMeasurement(-8.0f, -8.0f, 0.0f, true);
    std::this_thread::sleep_for(std::chrono::milliseconds(1100));
    const float lowered = brain.currentAutoLoudnessTrimDb();
    CHECK(lowered < raised - 0.8f,
          "high program loudness slowly unwinds the master trim");

    brain.setFrozen(true);
    const float frozen = brain.currentAutoLoudnessTrimDb();
    brain.pushMasterMeasurement(-30.0f, -30.0f, 0.0f, true);
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    CHECK(std::fabs(brain.currentAutoLoudnessTrimDb() - frozen) < 0.01f,
          "FREEZE holds the current loudness correction");
    brain.stop();

    app::BrainThread limited;
    limited.configure(0, 96000.0, {});
    limited.setScene(app::Scene::Sermon);
    limited.pushMasterMeasurement(-24.0f, -24.0f, 4.0f, true);
    limited.start();
    std::this_thread::sleep_for(std::chrono::milliseconds(550));
    limited.stop();
    CHECK(limited.currentAutoLoudnessTrimDb() <= -0.4f,
          "heavy limiter activity makes the loudness controller back away");
}

static std::pair<double, double> renderBrainTone(bool manualOverride) {
    const int frames = 256;
    const double fs = 96000.0;
    std::vector<app::Cls> roles{app::Cls::Bass};

    Engine eng;
    eng.prepare(fs, frames, 1);
    const auto profile = app::profileFor(roles[0]);
    eng.setChannelConfig(0, profile.bus, profile.isSpeech);

    app::BrainThread brain;
    brain.configure(1, fs, roles);
    brain.setScene(app::Scene::Sermon);
    if (manualOverride) {
        ChannelParams manual;
        manual.faderDb = 0.0f;
        manual.pan = 1.0f;
        CHECK(brain.setManualChannelParams(0, manual, app::OverrideFader | app::OverridePan), "accepts manual fader/pan override for behavior test");
    }
    brain.start();
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    brain.applyTo(eng);
    brain.stop();

    std::vector<float> in(frames), oL(frames), oR(frames);
    std::vector<const float*> ptrs{in.data()};
    double ph = 0.0;
    const double inc = 2 * M_PI * 120.0 / fs;
    for (int b = 0; b < 160; ++b) {
        for (int s = 0; s < frames; ++s) {
            in[s] = 0.003f * (float)std::sin(ph);
            ph += inc;
        }
        eng.process(ptrs.data(), 1, oL.data(), oR.data(), frames);
    }
    return {rms(oL, frames / 2), rms(oR, frames / 2)};
}

static void testBrainThreadManualOverrideBehavior() {
    std::printf("BrainThread (manual override beats scene automation)\n");
    const auto autoMix = renderBrainTone(false);
    const auto manualMix = renderBrainTone(true);

    CHECK(manualMix.second > autoMix.second * 4.0, "manual fader override wins over sermon scene fader ducking");
    CHECK(manualMix.second > manualMix.first * 3.0, "manual pan override moves the channel primarily right");
}

// Feed `seconds` of a click train at `bpm` into the tracker (impulse on each beat,
// zero between), at the given feature rate, and return the detected BPM.
static float runClickTrain(bdsp::BeatTracker& bt, double featureRate, double bpm, double seconds) {
    const double beatSamples = featureRate * 60.0 / bpm;
    const int total = (int)(featureRate * seconds);
    double nextBeat = 0.0;
    for (int n = 0; n < total; ++n) {
        float onset = 0.0f;
        if ((double)n >= nextBeat) { onset = 1.0f; nextBeat += beatSamples; }
        bt.push(onset);
    }
    return bt.bpm();
}

static void testBeatTracker() {
    std::printf("BeatTracker (control-rate tempo from onset envelope)\n");
    const double featureRate = 200.0;

    for (double targetBpm : {90.0, 120.0, 140.0}) {
        bdsp::BeatTracker bt;
        bt.reset(featureRate);
        const float detected = runClickTrain(bt, featureRate, targetBpm, 8.0);
        char msg[96];
        std::snprintf(msg, sizeof(msg), "detects %.0f BPM click train (got %.1f)", targetBpm, detected);
        CHECK(std::fabs(detected - targetBpm) <= 3.0, msg);
        CHECK(bt.confidence() > 0.5f, "clean click train yields high confidence");
    }

    // Random noise should not masquerade as a confident tempo.
    bdsp::BeatTracker noiseBt;
    noiseBt.reset(featureRate);
    std::mt19937 rng(1234);
    std::uniform_real_distribution<float> dist(0.0f, 1.0f);
    for (int n = 0; n < (int)(featureRate * 8.0); ++n) noiseBt.push(dist(rng));
    CHECK(noiseBt.confidence() < 0.5f, "white-noise onset envelope yields low confidence");

    // No data yet -> no estimate.
    bdsp::BeatTracker empty;
    empty.reset(featureRate);
    CHECK(empty.bpm() == 0.0f, "tracker reports no tempo before enough data");
}

static void testOnsetDetector() {
    std::printf("OnsetDetector (transient flux at a fixed feature rate)\n");
    bdsp::OnsetDetector od;
    od.prepare(FS, 200.0);
    CHECK(std::fabs(od.featureRate() - 200.0) < 5.0, "feature rate is ~200 Hz");

    // Sustained tone -> ~0 onset (skip its attack, which is itself a real onset);
    // a sudden burst -> a positive onset feature.
    float steadyMax = 0.0f, burstMax = 0.0f;
    float out = 0.0f;
    const int attackSkip = (int)(FS * 0.1);
    for (int n = 0; n < (int)FS; ++n) {            // 1s steady tone
        float x = 0.3f * std::sin(2.0 * M_PI * 220.0 * n / FS);
        if (od.process(x, out) && n > attackSkip) steadyMax = std::max(steadyMax, out);
    }
    for (int n = 0; n < (int)(FS * 0.2); ++n) {    // a louder burst
        float x = (n < 200) ? 1.0f : 0.0f;
        if (od.process(x, out)) burstMax = std::max(burstMax, out);
    }
    CHECK(burstMax > 0.3f && burstMax > steadyMax * 3.0f,
          "a transient burst produces a much larger onset than a sustained tone");
}

static void testOnsetFeedsBeatTracker() {
    std::printf("OnsetDetector -> BeatTracker (tempo from an audio click train)\n");
    bdsp::OnsetDetector od;
    od.prepare(FS, 200.0);
    bdsp::BeatTracker bt;
    bt.reset(od.featureRate());

    const double bpm = 120.0;
    const double clickSamples = FS * 60.0 / bpm;   // one click per beat
    double nextClick = 0.0;
    float out = 0.0f;
    for (int n = 0; n < (int)(FS * 8.0); ++n) {
        float x = 0.0f;
        if ((double)n >= nextClick) { x = 1.0f; nextClick += clickSamples; }
        if (od.process(x, out)) bt.push(out);
    }
    char msg[96];
    std::snprintf(msg, sizeof(msg), "audio 120 BPM click train tracked (got %.1f)", bt.bpm());
    CHECK(std::fabs(bt.bpm() - 120.0) <= 4.0, msg);
}

static void testEngineOnsetTempo() {
    std::printf("Engine -> onset ring -> BeatTracker (tempo from the live mix)\n");
    bdsp::Engine eng;
    const int block = 256;
    eng.prepare(FS, block, 1);
    eng.setChannelConfig(0, bdsp::BusId::Band, false);
    bdsp::ChannelParams cp;
    cp.faderDb = 0.0f;
    eng.setChannelParams(0, cp);

    bdsp::BeatTracker bt;
    bt.reset(eng.onsetFeatureRate());

    const double bpm = 120.0;
    const double clickSamples = FS * 60.0 / bpm;
    double nextClick = 0.0;
    std::vector<float> in((size_t)block, 0.0f);
    std::vector<float> oL((size_t)block, 0.0f), oR((size_t)block, 0.0f);
    float drain[1024];

    const int totalBlocks = (int)(FS * 8.0 / block);
    long n = 0;
    for (int b = 0; b < totalBlocks; ++b) {
        for (int s = 0; s < block; ++s, ++n) {
            float x = 0.0f;
            if ((double)n >= nextClick) { x = 1.0f; nextClick += clickSamples; }
            in[(size_t)s] = x;
        }
        const float* ins[1] = { in.data() };
        eng.process(ins, 1, oL.data(), oR.data(), block);
        int got = eng.drainOnsets(drain, 1024);
        for (int i = 0; i < got; ++i) bt.push(drain[i]);
    }
    char msg[96];
    std::snprintf(msg, sizeof(msg), "live-mix 120 BPM tracked end to end (got %.1f)", bt.bpm());
    CHECK(std::fabs(bt.bpm() - 120.0) <= 5.0, msg);
}

static void testReverb() {
    std::printf("Reverb (stereo FDN: stable, decaying, decorrelated)\n");
    bdsp::Reverb rev;
    rev.prepare(FS, /*decaySeconds*/ 1.5f, /*damping*/ 0.3f, /*sizeMul*/ 1.0f);

    // Impulse in, then silence. Collect the tail.
    float peakEarly = 0.0f, peakLate = 0.0f, diffSum = 0.0f;
    bool allFinite = true;
    const int total = (int)(FS * 4.0);
    const int earlyEnd = (int)(FS * 0.5);
    const int lateStart = (int)(FS * 3.5);
    for (int n = 0; n < total; ++n) {
        float in = (n == 0) ? 1.0f : 0.0f;
        float l = 0.0f, r = 0.0f;
        rev.process(in, l, r);
        if (!std::isfinite(l) || !std::isfinite(r)) allFinite = false;
        const float mag = std::max(std::fabs(l), std::fabs(r));
        if (n < earlyEnd) peakEarly = std::max(peakEarly, mag);
        if (n >= lateStart) peakLate = std::max(peakLate, mag);
        diffSum += std::fabs(l - r);
    }

    CHECK(allFinite, "reverb output stays finite (no blowup)");
    CHECK(peakEarly > 1e-4f, "reverb produces an audible early tail after an impulse");
    CHECK(peakLate < peakEarly * 0.2f, "reverb tail decays well below the early energy");
    CHECK(diffSum > 0.0f, "reverb L/R are decorrelated (stereo)");
}

static void testReverbNoAllocationInProcess() {
    std::printf("Reverb (realtime no-allocation invariant)\n");
    bdsp::Reverb rev;
    rev.prepare(FS, 1.5f, 0.3f, 1.0f);
    float l = 0.0f, r = 0.0f;
    {
        AllocationGuard guard;
        for (int n = 0; n < 4096; ++n) rev.process(n == 0 ? 1.0f : 0.0f, l, r);
    }
    CHECK(g_allocationsWhileGuarded.load() == 0, "reverb process does not allocate");
}

static void testTempoDelay() {
    std::printf("TempoDelay (ping-pong, tempo-synced, feedback-safe)\n");
    bdsp::TempoDelay dly;
    dly.prepare(FS, /*maxSeconds*/ 2.0f);
    dly.setFeedback(0.5f);
    dly.setTimeSeconds(0.25f);
    const int delaySamples = (int)std::lround(0.25 * FS);

    int firstLPeakIdx = -1, firstRPeakIdx = -1;
    float firstLPeak = 0.0f, firstRPeak = 0.0f, thirdLPeak = 0.0f;
    bool finite = true;
    const int total = delaySamples * 5;
    for (int n = 0; n < total; ++n) {
        float l = 0.0f, r = 0.0f;
        dly.process(n == 0 ? 1.0f : 0.0f, l, r);
        if (!std::isfinite(l) || !std::isfinite(r)) finite = false;
        if (std::fabs(l) > firstLPeak && n < delaySamples * 2) { firstLPeak = std::fabs(l); firstLPeakIdx = n; }
        if (std::fabs(r) > firstRPeak && n < delaySamples * 3) { firstRPeak = std::fabs(r); firstRPeakIdx = n; }
        if (n >= delaySamples * 3 - 2 && n <= delaySamples * 3 + 2) thirdLPeak = std::max(thirdLPeak, std::fabs(l));
    }

    CHECK(finite, "delay output stays finite");
    CHECK(std::abs(firstLPeakIdx - delaySamples) <= 2, "first left echo lands one delay time in");
    CHECK(std::abs(firstRPeakIdx - 2 * delaySamples) <= 2, "ping-pong right echo lands two delay times in");
    CHECK(std::fabs(thirdLPeak - 0.25f) < 0.05f, "feedback decays (3rd tap ~ fb^2)");
}

static void testTempoDelaySyncAndFeedbackSafety() {
    std::printf("TempoDelay (BPM->time mapping + feedback clamp)\n");
    // Eighth note at 120 BPM = 0.25 s.
    bdsp::TempoDelay dly;
    dly.prepare(FS, 2.0f);
    dly.setTempo(120.0f, 0.5f);   // 0.5 = eighth (half a quarter)
    const int expected = (int)std::lround(0.25 * FS);
    int peakIdx = -1; float peak = 0.0f;
    for (int n = 0; n < expected * 2; ++n) {
        float l = 0.0f, r = 0.0f;
        dly.process(n == 0 ? 1.0f : 0.0f, l, r);
        if (std::fabs(l) > peak) { peak = std::fabs(l); peakIdx = n; }
    }
    CHECK(std::abs(peakIdx - expected) <= 2, "120 BPM eighth note delays by 0.25 s");

    // Absurd feedback must be clamped so the line can never run away.
    bdsp::TempoDelay hot;
    hot.prepare(FS, 2.0f);
    hot.setTimeSeconds(0.1f);
    hot.setFeedback(5.0f);
    float maxMag = 0.0f; bool finite = true;
    for (int n = 0; n < (int)(FS * 5.0); ++n) {
        float l = 0.0f, r = 0.0f;
        hot.process(n == 0 ? 1.0f : 0.0f, l, r);
        maxMag = std::max(maxMag, std::max(std::fabs(l), std::fabs(r)));
        if (!std::isfinite(l) || !std::isfinite(r)) finite = false;
    }
    CHECK(finite && maxMag < 4.0f, "clamped feedback keeps the delay bounded");
}

static void testTempoDelayNoAllocationInProcess() {
    std::printf("TempoDelay (realtime no-allocation invariant)\n");
    bdsp::TempoDelay dly;
    dly.prepare(FS, 2.0f);
    dly.setTimeSeconds(0.25f);
    dly.setFeedback(0.4f);
    float l = 0.0f, r = 0.0f;
    {
        AllocationGuard guard;
        for (int n = 0; n < 4096; ++n) dly.process(n == 0 ? 1.0f : 0.0f, l, r);
    }
    CHECK(g_allocationsWhileGuarded.load() == 0, "delay process does not allocate");
}

int main() {
    std::printf("=== Broadcast DSP core — correctness tests ===\n");
    testDefaultSampleRate();
    testSVF();
    testLoudness();
    testLimiter();
    testAutomix();
    testCompressor();
    testGate();
    testEngine();
    testEngine96kAndRouting();
    testEngineProcessNoAllocation();
    testEngineMasterLoudnessTrim();
    testBrainThreadControls();
    testBrainThreadManualOverrideBehavior();
    testBrainMeasurementDrivenGainStaging();
    testBrainMasterLoudnessControl();
    testBeatTracker();
    testOnsetDetector();
    testOnsetFeedsBeatTracker();
    testEngineOnsetTempo();
    testReverb();
    testReverbNoAllocationInProcess();
    testTempoDelay();
    testTempoDelaySyncAndFeedbackSafety();
    testTempoDelayNoAllocationInProcess();
    std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
