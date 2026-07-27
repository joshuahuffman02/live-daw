// BrainThread.h — the control-rate half of the two-rate design (the spec's "brain").
// Runs at ~20 Hz on its OWN thread, computes parameter TARGETS, and hands them to the
// audio thread through an atomic mailbox so the audio callback NEVER blocks or locks. A
// watchdog drops the engine to the SAFE mix if the brain stalls.
//
// This is a skeleton: the parameter math here is a static per-class profile table +
// scene offsets (mirrors web/src/brain/targets.ts & scenes.ts). The live pieces — the
// ONNX/Core ML channel classifier, the spectral auto-EQ, and the cross-channel
// masking — plug in at the marked integration points. The full, working reference
// implementation of all of that is the TypeScript brain in ../web/src/brain.
#pragma once
#include "Engine.h"
#include "BeatTracker.h"
#include "Params.h"
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace app {

enum class Cls { Speech, LeadVocal, Bgv, Acoustic, Electric, Bass, Kick, Keys, Unknown };
enum class Scene { PreService, Worship, Sermon, Prayer, PostService };

// ---- integration point: channel classifier -------------------------------
// In the appliance this is backed by a small int8 CNN (ONNX Runtime / Core ML)
// running on log-mel spectrograms. Here it's an interface with a pass-through stub.
struct IClassifier {
    virtual ~IClassifier() = default;
    // given a channel's recent audio block, return (class, confidence)
    virtual std::pair<Cls, float> classify(const float* mono, int frames, double fs) = 0;
};

struct SourceProfile {
    bdsp::BusId bus;
    bool isSpeech;
    float hpfHz;
    bool gateEnabled; float gateRatio, gateRangeDb, gateOffsetDb;
    float compThreshDb, compRatio, compAttack, compRelease, compKnee;
    std::array<bdsp::EqBandParam, 3> voice;
    float pan;
};

inline SourceProfile profileFor(Cls c) {
    using T = bdsp::SVF;
    switch (c) {
        case Cls::Speech:    return {bdsp::BusId::Speech, true, 100, false, 2, 10, 8, -26, 3.5f, .006f, .18f, 8, {{{T::Bell,300,1.1f,-2.5f},{T::Bell,3400,1.0f,3.0f},{T::HighShelf,9000,0.7f,2.0f}}}, 0};
        case Cls::LeadVocal: return {bdsp::BusId::Vocals, false, 90, false, 2, 8, 10, -24, 3.0f, .008f, .16f, 10, {{{T::Bell,250,1.0f,-2.0f},{T::Bell,3000,0.9f,2.5f},{T::HighShelf,11000,0.7f,2.5f}}}, 0};
        case Cls::Bgv:       return {bdsp::BusId::Vocals, false, 120, false, 2, 8, 10, -26, 3.0f, .010f, .18f, 10, {{{T::Bell,300,1.0f,-3.0f},{T::Bell,2500,1.2f,-1.0f},{T::HighShelf,10000,0.7f,1.5f}}}, 0.35f};
        case Cls::Acoustic:  return {bdsp::BusId::Band, false, 90, false, 2, 12, 10, -22, 2.5f, .012f, .20f, 8, {{{T::Bell,200,1.1f,-3.0f},{T::Bell,2500,0.9f,1.5f},{T::HighShelf,9000,0.7f,1.5f}}}, -0.3f};
        case Cls::Electric:  return {bdsp::BusId::Band, false, 100, true, 4, 14, 12, -20, 2.5f, .015f, .18f, 6, {{{T::Bell,400,1.2f,-2.0f},{T::Bell,1800,1.0f,1.0f},{T::LowPass,9000,0.7f,0}}}, 0.3f};
        case Cls::Bass:      return {bdsp::BusId::Band, false, 35, false, 2, 10, 10, -20, 3.5f, .020f, .12f, 6, {{{T::Bell,80,0.9f,1.5f},{T::Bell,700,1.0f,1.0f},{T::LowPass,6000,0.7f,0}}}, 0};
        case Cls::Kick:      return {bdsp::BusId::Drums, false, 30, true, 6, 18, 14, -18, 4.0f, .004f, .10f, 4, {{{T::Bell,60,1.0f,2.0f},{T::Bell,400,1.3f,-3.0f},{T::Bell,3500,1.0f,2.0f}}}, 0};
        case Cls::Keys:      return {bdsp::BusId::Band, false, 60, false, 2, 10, 10, -24, 2.5f, .020f, .25f, 10, {{{T::Bell,300,1.0f,-2.0f},{T::HighShelf,8000,0.7f,1.0f},{T::LowShelf,120,0.7f,-1.5f}}}, -0.2f};
        default:             return {bdsp::BusId::Band, false, 80, false, 2, 8, 12, -24, 2.0f, .020f, .20f, 10, {{{T::Bell,1000,1,0},{T::Bell,2000,1,0},{T::Bell,4000,1,0}}}, 0};
    }
}

// scene -> (per-band fader offset already folded in by caller) speech active + LUFS target
inline float sceneFaderOffset(Scene s, bdsp::BusId bus) {
    switch (s) {
        case Scene::Worship:     return bus == bdsp::BusId::Vocals ? 1.0f : 0.0f;
        case Scene::Sermon:      return bus == bdsp::BusId::Speech ? 2.0f : (bus == bdsp::BusId::Drums ? -60.0f : -16.0f);
        case Scene::Prayer:      return bus == bdsp::BusId::Speech ? 0.0f : -12.0f;
        case Scene::PreService:
        case Scene::PostService: return bus == bdsp::BusId::Band ? -10.0f : -60.0f;
    }
    return 0.0f;
}
inline float sceneTargetLufs(Scene s) { return s == Scene::Worship ? -14.0f : -15.0f; }

struct EngineSnapshot {
    static constexpr int kMaxCh = 64;
    int numCh = 0;
    std::array<bdsp::ChannelParams, kMaxCh> ch{};
    bdsp::MasterParams master{};
    bool bypass = false;
};

using OverrideMask = uint32_t;
enum ParamOverride : OverrideMask {
    OverrideTrim   = 1u << 0,
    OverrideHpf    = 1u << 1,
    OverrideGate   = 1u << 2,
    OverrideEq     = 1u << 3,
    OverrideComp   = 1u << 4,
    OverrideFader  = 1u << 5,
    OverridePan    = 1u << 6,
    OverrideReverb = 1u << 7,
    OverrideAll    = OverrideTrim | OverrideHpf | OverrideGate | OverrideEq |
                     OverrideComp | OverrideFader | OverridePan | OverrideReverb,
};

struct AtomicEqBandParam {
    std::atomic<int> type{(int)bdsp::SVF::Bell};
    std::atomic<float> freq{1000.0f};
    std::atomic<float> q{1.0f};
    std::atomic<float> gainDb{0.0f};

    void store(const bdsp::EqBandParam& p) {
        type.store((int)p.type, std::memory_order_relaxed);
        freq.store(p.freq, std::memory_order_relaxed);
        q.store(p.q, std::memory_order_relaxed);
        gainDb.store(p.gainDb, std::memory_order_relaxed);
    }

    bdsp::EqBandParam load() const {
        return {
            (bdsp::SVF::Type)type.load(std::memory_order_relaxed),
            freq.load(std::memory_order_relaxed),
            q.load(std::memory_order_relaxed),
            gainDb.load(std::memory_order_relaxed)
        };
    }
};

struct AtomicChannelParams {
    std::atomic<float> trimDb{0.0f};
    std::atomic<float> hpfHz{80.0f};
    std::atomic<bool> gateEnabled{false};
    std::atomic<float> gateThreshDb{-45.0f};
    std::atomic<float> gateRatio{2.5f};
    std::atomic<float> gateRangeDb{14.0f};
    std::array<AtomicEqBandParam, 2> corr{};
    std::array<AtomicEqBandParam, 2> mask{};
    std::array<AtomicEqBandParam, 3> voice{};
    AtomicEqBandParam deEss{};
    std::atomic<float> compThreshDb{-24.0f};
    std::atomic<float> compRatio{2.5f};
    std::atomic<float> compAttack{0.01f};
    std::atomic<float> compRelease{0.2f};
    std::atomic<float> compKnee{8.0f};
    std::atomic<float> compMakeupDb{0.0f};
    std::atomic<float> faderDb{-6.0f};
    std::atomic<float> pan{0.0f};
    std::atomic<float> reverbSendDb{-60.0f};
    std::atomic<bool> isSpeech{false};

    void store(const bdsp::ChannelParams& p) {
        trimDb.store(p.trimDb, std::memory_order_relaxed);
        hpfHz.store(p.hpfHz, std::memory_order_relaxed);
        gateEnabled.store(p.gateEnabled, std::memory_order_relaxed);
        gateThreshDb.store(p.gateThreshDb, std::memory_order_relaxed);
        gateRatio.store(p.gateRatio, std::memory_order_relaxed);
        gateRangeDb.store(p.gateRangeDb, std::memory_order_relaxed);
        for (size_t i = 0; i < corr.size(); ++i) corr[i].store(p.corr[i]);
        for (size_t i = 0; i < mask.size(); ++i) mask[i].store(p.mask[i]);
        for (size_t i = 0; i < voice.size(); ++i) voice[i].store(p.voice[i]);
        deEss.store(p.deEss);
        compThreshDb.store(p.compThreshDb, std::memory_order_relaxed);
        compRatio.store(p.compRatio, std::memory_order_relaxed);
        compAttack.store(p.compAttack, std::memory_order_relaxed);
        compRelease.store(p.compRelease, std::memory_order_relaxed);
        compKnee.store(p.compKnee, std::memory_order_relaxed);
        compMakeupDb.store(p.compMakeupDb, std::memory_order_relaxed);
        faderDb.store(p.faderDb, std::memory_order_relaxed);
        pan.store(p.pan, std::memory_order_relaxed);
        reverbSendDb.store(p.reverbSendDb, std::memory_order_relaxed);
        isSpeech.store(p.isSpeech, std::memory_order_relaxed);
    }

    bdsp::ChannelParams load() const {
        bdsp::ChannelParams p;
        p.trimDb = trimDb.load(std::memory_order_relaxed);
        p.hpfHz = hpfHz.load(std::memory_order_relaxed);
        p.gateEnabled = gateEnabled.load(std::memory_order_relaxed);
        p.gateThreshDb = gateThreshDb.load(std::memory_order_relaxed);
        p.gateRatio = gateRatio.load(std::memory_order_relaxed);
        p.gateRangeDb = gateRangeDb.load(std::memory_order_relaxed);
        for (size_t i = 0; i < corr.size(); ++i) p.corr[i] = corr[i].load();
        for (size_t i = 0; i < mask.size(); ++i) p.mask[i] = mask[i].load();
        for (size_t i = 0; i < voice.size(); ++i) p.voice[i] = voice[i].load();
        p.deEss = deEss.load();
        p.compThreshDb = compThreshDb.load(std::memory_order_relaxed);
        p.compRatio = compRatio.load(std::memory_order_relaxed);
        p.compAttack = compAttack.load(std::memory_order_relaxed);
        p.compRelease = compRelease.load(std::memory_order_relaxed);
        p.compKnee = compKnee.load(std::memory_order_relaxed);
        p.compMakeupDb = compMakeupDb.load(std::memory_order_relaxed);
        p.faderDb = faderDb.load(std::memory_order_relaxed);
        p.pan = pan.load(std::memory_order_relaxed);
        p.reverbSendDb = reverbSendDb.load(std::memory_order_relaxed);
        p.isSpeech = isSpeech.load(std::memory_order_relaxed);
        return p;
    }
};

struct AtomicMasterParams {
    std::atomic<float> glueThreshDb{-18.0f};
    std::atomic<float> glueRatio{2.0f};
    std::atomic<float> targetLufs{-14.0f};
    std::atomic<float> ceilingDbTP{-1.0f};
    std::atomic<float> reverbReturnDb{-12.0f};
    std::atomic<float> reverbDecaySeconds{1.8f};
    std::atomic<float> reverbDamping{0.3f};
    std::atomic<float> delayWetDb{-120.0f};
    std::atomic<float> delayTimeSeconds{0.35f};
    std::atomic<float> delayFeedback{0.35f};

    void store(const bdsp::MasterParams& p) {
        glueThreshDb.store(p.glueThreshDb, std::memory_order_relaxed);
        glueRatio.store(p.glueRatio, std::memory_order_relaxed);
        targetLufs.store(p.targetLufs, std::memory_order_relaxed);
        ceilingDbTP.store(p.ceilingDbTP, std::memory_order_relaxed);
        reverbReturnDb.store(p.reverbReturnDb, std::memory_order_relaxed);
        reverbDecaySeconds.store(p.reverbDecaySeconds, std::memory_order_relaxed);
        reverbDamping.store(p.reverbDamping, std::memory_order_relaxed);
        delayWetDb.store(p.delayWetDb, std::memory_order_relaxed);
        delayTimeSeconds.store(p.delayTimeSeconds, std::memory_order_relaxed);
        delayFeedback.store(p.delayFeedback, std::memory_order_relaxed);
    }

    bdsp::MasterParams load() const {
        bdsp::MasterParams p;
        p.glueThreshDb = glueThreshDb.load(std::memory_order_relaxed);
        p.glueRatio = glueRatio.load(std::memory_order_relaxed);
        p.targetLufs = targetLufs.load(std::memory_order_relaxed);
        p.ceilingDbTP = ceilingDbTP.load(std::memory_order_relaxed);
        p.reverbReturnDb = reverbReturnDb.load(std::memory_order_relaxed);
        p.reverbDecaySeconds = reverbDecaySeconds.load(std::memory_order_relaxed);
        p.reverbDamping = reverbDamping.load(std::memory_order_relaxed);
        p.delayWetDb = delayWetDb.load(std::memory_order_relaxed);
        p.delayTimeSeconds = delayTimeSeconds.load(std::memory_order_relaxed);
        p.delayFeedback = delayFeedback.load(std::memory_order_relaxed);
        return p;
    }
};

struct AtomicEngineSnapshot {
    std::atomic<int> numCh{0};
    std::array<AtomicChannelParams, EngineSnapshot::kMaxCh> ch{};
    AtomicMasterParams master{};
    std::atomic<bool> bypass{false};

    void store(const EngineSnapshot& s) {
        numCh.store(s.numCh, std::memory_order_relaxed);
        for (int i = 0; i < s.numCh; ++i) ch[(size_t)i].store(s.ch[(size_t)i]);
        master.store(s.master);
        bypass.store(s.bypass, std::memory_order_relaxed);
    }

    EngineSnapshot load() const {
        EngineSnapshot s;
        s.numCh = numCh.load(std::memory_order_relaxed);
        if (s.numCh < 0) s.numCh = 0;
        if (s.numCh > EngineSnapshot::kMaxCh) s.numCh = EngineSnapshot::kMaxCh;
        for (int i = 0; i < s.numCh; ++i) s.ch[(size_t)i] = ch[(size_t)i].load();
        s.master = master.load();
        s.bypass = bypass.load(std::memory_order_relaxed);
        return s;
    }
};

// One-way audio-thread -> brain-thread measurement transport. Every field is atomic,
// so the Core Audio callback publishes the latest completed block without allocating,
// locking, or handing audio buffers to the control thread.
struct AtomicChannelMeasurement {
    std::atomic<float> inputRmsDb{-100.0f};
    std::atomic<float> inputPeakDb{-100.0f};
    std::atomic<float> postRmsDb{-100.0f};
};

class BrainThread {
public:
    void configure(int numCh, double fs, const std::vector<Cls>& assignedClasses) {
        if (numCh < 0 || numCh > EngineSnapshot::kMaxCh)
            throw std::invalid_argument("BrainThread supports 0..64 channels");
        std::lock_guard<std::mutex> lk(controlMutex_);
        numCh_ = numCh;
        fs_ = fs;
        classes_.fill(Cls::Unknown);
        for (int i = 0; i < numCh_; ++i) {
            classes_[(size_t)i] = i < (int)assignedClasses.size() ? assignedClasses[(size_t)i] : Cls::Unknown;
        }
        overrideMask_.fill(0);
        manualParams_.fill(bdsp::ChannelParams{});
        for (int i = 0; i < EngineSnapshot::kMaxCh; ++i) {
            measurements_[(size_t)i].inputRmsDb.store(-100.0f, std::memory_order_relaxed);
            measurements_[(size_t)i].inputPeakDb.store(-100.0f, std::memory_order_relaxed);
            measurements_[(size_t)i].postRmsDb.store(-100.0f, std::memory_order_relaxed);
            noiseFloorDb_[(size_t)i] = -60.0f;
            slowInputRmsDb_[(size_t)i] = -100.0f;
            slowPostRmsDb_[(size_t)i] = -100.0f;
            autoTrimDb_[(size_t)i] = 0.0f;
            autoFaderDb_[(size_t)i] = -6.0f;
            activeHoldTicks_[(size_t)i] = 0;
            haveActiveMeasurement_[(size_t)i] = false;
            autoTrimPublished_[(size_t)i].store(0.0f, std::memory_order_relaxed);
            autoFaderPublished_[(size_t)i].store(-6.0f, std::memory_order_relaxed);
            noiseFloorPublished_[(size_t)i].store(-60.0f, std::memory_order_relaxed);
            activePublished_[(size_t)i].store(false, std::memory_order_relaxed);
        }
    }
    void setScene(Scene s) { scene_.store((int)s); }
    void setFrozen(bool f) { frozen_.store(f); }
    void setOperatorBypass(bool b) { opBypass_.store(b); }
    bool watchdogBypassActive() const { return watchdogBypass_.load(std::memory_order_relaxed); }

    // Wire the engine whose onset features this brain tracks. Call after the engine is
    // prepared and before start(). The brain drains onsets on its own thread (SPSC with
    // the audio thread) to estimate tempo — never on the audio callback.
    void setOnsetSource(bdsp::Engine* engine) {
        onsetEngine_ = engine;
        if (engine) beatTracker_.reset(engine->onsetFeatureRate());
    }
    float currentBpm() const { return bpm_.load(std::memory_order_relaxed); }
    float currentBpmConfidence() const { return bpmConfidence_.load(std::memory_order_relaxed); }
    void pushChannelMeasurement(int channel, float inputRmsDb, float inputPeakDb, float postRmsDb) {
        if (channel < 0 || channel >= EngineSnapshot::kMaxCh) return;
        auto& m = measurements_[(size_t)channel];
        m.inputRmsDb.store(sanitizeDb(inputRmsDb), std::memory_order_relaxed);
        m.inputPeakDb.store(sanitizeDb(inputPeakDb), std::memory_order_relaxed);
        m.postRmsDb.store(sanitizeDb(postRmsDb), std::memory_order_release);
    }
    float currentAutoTrimDb(int channel) const {
        return validChannelSlot(channel)
            ? autoTrimPublished_[(size_t)channel].load(std::memory_order_relaxed)
            : 0.0f;
    }
    float currentAutoFaderDb(int channel) const {
        return validChannelSlot(channel)
            ? autoFaderPublished_[(size_t)channel].load(std::memory_order_relaxed)
            : -80.0f;
    }
    float currentNoiseFloorDb(int channel) const {
        return validChannelSlot(channel)
            ? noiseFloorPublished_[(size_t)channel].load(std::memory_order_relaxed)
            : -100.0f;
    }
    bool channelActive(int channel) const {
        return validChannelSlot(channel) &&
            activePublished_[(size_t)channel].load(std::memory_order_relaxed);
    }
#if DEBUG
    void debugSetTickPausedForTesting(bool paused) {
        debugTickPaused_.store(paused, std::memory_order_relaxed);
        const int64_t now = nowMs();
        lastTickMs_.store(paused ? now - 1000 : now, std::memory_order_relaxed);
        if (!paused) watchdogBypass_.store(false, std::memory_order_relaxed);
    }
#endif

    // Called by the supervisory UI/control layer, never by the audio callback.
    // Each mask bit protects that parameter family from brain-written targets.
    bool setManualChannelParams(int channel, const bdsp::ChannelParams& params, OverrideMask mask) {
        if (channel < 0 || channel >= numCh_) return false;
        std::lock_guard<std::mutex> lk(controlMutex_);
        manualParams_[(size_t)channel] = params;
        overrideMask_[(size_t)channel] = mask;
        return true;
    }
    bool clearManualOverrides(int channel, OverrideMask mask = OverrideAll) {
        if (channel < 0 || channel >= numCh_) return false;
        std::lock_guard<std::mutex> lk(controlMutex_);
        overrideMask_[(size_t)channel] &= ~mask;
        return true;
    }
    bool setAssignedClass(int channel, Cls assignedClass) {
        if (channel < 0 || channel >= numCh_) return false;
        std::lock_guard<std::mutex> lk(controlMutex_);
        classes_[(size_t)channel] = assignedClass;
        return true;
    }

    void start() {
        watchdogBypass_.store(false, std::memory_order_relaxed);
        running_.store(true);
        lastTickMs_.store(nowMs());
        th_ = std::thread([this] { run(); });
    }
    void stop() {
        running_.store(false);
        if (th_.joinable()) th_.join();
    }

    // ---- called on the AUDIO thread, once per block. Never blocks. ----
    void applyTo(bdsp::Engine& e) {
        // failsafe watchdog: if the brain hasn't ticked recently, drop to SAFE mix
        if (nowMs() - lastTickMs_.load() > 600) {
            watchdogBypass_.store(true, std::memory_order_relaxed);
            e.setBypass(true);
            return;
        }
        watchdogBypass_.store(false, std::memory_order_relaxed);
        const uint64_t seq = publishSeq_.load(std::memory_order_acquire);
        if ((seq & 1u) != 0 || seq == appliedSeq_) return;

        EngineSnapshot s;
        if (!tryLoadPublishedSnapshot(seq, s)) return;
        for (int i = 0; i < s.numCh; ++i) e.setChannelParams(i, s.ch[i]);
        e.setMasterParams(s.master);
        e.setBypass(s.bypass);
        appliedSeq_ = seq;
    }

private:
    static int64_t nowMs() {
        using namespace std::chrono;
        return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
    }

    static bool validChannelSlot(int channel) {
        return channel >= 0 && channel < EngineSnapshot::kMaxCh;
    }

    static float sanitizeDb(float value) {
        if (!std::isfinite(value)) return -100.0f;
        return std::max(-100.0f, std::min(24.0f, value));
    }

    static float approach(float current, float target, float maxStep) {
        if (target > current) return std::min(target, current + maxStep);
        return std::max(target, current - maxStep);
    }

    static float targetPostRmsDb(Cls c) {
        switch (c) {
            case Cls::Speech:
            case Cls::LeadVocal: return -21.0f;
            case Cls::Bgv: return -26.0f;
            case Cls::Bass: return -25.0f;
            case Cls::Kick: return -24.0f;
            case Cls::Acoustic:
            case Cls::Electric: return -27.0f;
            case Cls::Keys: return -28.0f;
            case Cls::Unknown: return -30.0f;
        }
        return -30.0f;
    }

    void updateMeasurementState(int channel, Cls assignedClass) {
        const size_t i = (size_t)channel;
        const float inputDb = measurements_[i].inputRmsDb.load(std::memory_order_relaxed);
        const float postDb = measurements_[i].postRmsDb.load(std::memory_order_acquire);
        const bool measured = inputDb > -99.0f;

        // A source is active only with useful signal above both a fixed floor and the
        // learned idle floor. A short hold prevents syllable gaps from pumping the
        // level rider. Unknown/unassigned channels remain measured but are not ridden.
        const float activeThreshold = std::max(-50.0f, noiseFloorDb_[i] + 12.0f);
        if (measured && inputDb > activeThreshold) {
            activeHoldTicks_[i] = 10; // 500 ms at the 20 Hz brain rate
        } else if (activeHoldTicks_[i] > 0) {
            --activeHoldTicks_[i];
        }
        const bool active = activeHoldTicks_[i] > 0;

        // Learn the idle floor only while inactive. Downward changes settle quickly;
        // upward changes are intentionally slow so a sustained source cannot become
        // its own "noise floor" and switch the automation off.
        if (measured && !active && inputDb < -35.0f) {
            const float alpha = inputDb < noiseFloorDb_[i] ? 0.20f : 0.015f;
            noiseFloorDb_[i] += alpha * (inputDb - noiseFloorDb_[i]);
        }

        if (active) {
            if (!haveActiveMeasurement_[i]) {
                slowInputRmsDb_[i] = inputDb;
                slowPostRmsDb_[i] = postDb;
                haveActiveMeasurement_[i] = true;
            } else {
                slowInputRmsDb_[i] = 0.92f * slowInputRmsDb_[i] + 0.08f * inputDb;
                if (postDb > -99.0f) {
                    slowPostRmsDb_[i] = 0.90f * slowPostRmsDb_[i] + 0.10f * postDb;
                }
            }
        }

        if (assignedClass != Cls::Unknown && active && haveActiveMeasurement_[i]) {
            // Conservative input gain staging: converge toward -18 dBFS RMS, with a
            // bounded range and a 5 dB/s maximum move. This is slow enough not to chase
            // words or notes but fast enough to settle during soundcheck.
            const float trimTarget = std::max(
                -6.0f,
                std::min(18.0f, -18.0f - slowInputRmsDb_[i])
            );
            autoTrimDb_[i] = approach(autoTrimDb_[i], trimTarget, 0.25f);
        }

        activePublished_[i].store(active, std::memory_order_relaxed);
        noiseFloorPublished_[i].store(noiseFloorDb_[i], std::memory_order_relaxed);
        autoTrimPublished_[i].store(autoTrimDb_[i], std::memory_order_relaxed);
    }

    void run() {
        while (running_.load()) {
#if DEBUG
            if (debugTickPaused_.load(std::memory_order_relaxed)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                continue;
            }
#endif
            updateTempo();   // track BPM regardless of FREEZE (informational)
            if (!frozen_.load()) {
                EngineSnapshot s;
                computeTargets(s);
                publishSnapshot(s);
            }
            lastTickMs_.store(nowMs());
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    }

    void updateTempo() {
        if (!onsetEngine_) return;
        float buf[512];
        const int got = onsetEngine_->drainOnsets(buf, 512);
        for (int i = 0; i < got; ++i) beatTracker_.push(buf[i]);
        bpm_.store(beatTracker_.bpm(), std::memory_order_relaxed);
        bpmConfidence_.store(beatTracker_.confidence(), std::memory_order_relaxed);
    }

    void publishSnapshot(const EngineSnapshot& s) {
        const uint64_t seq = publishSeq_.load(std::memory_order_relaxed);
        publishSeq_.store(seq + 1u, std::memory_order_release);
        published_.store(s);
        publishSeq_.store(seq + 2u, std::memory_order_release);
    }

    bool tryLoadPublishedSnapshot(uint64_t expectedSeq, EngineSnapshot& out) const {
        out = published_.load();
        const uint64_t seqAfter = publishSeq_.load(std::memory_order_acquire);
        return seqAfter == expectedSeq && (seqAfter & 1u) == 0;
    }

    void computeTargets(EngineSnapshot& s) {
        const Scene scene = (Scene)scene_.load();
        s.bypass = opBypass_.load();
        s.master.targetLufs = sceneTargetLufs(scene);
        s.master.ceilingDbTP = -1.0f;

        // Production FX targets (conservative): a clean room reverb on every scene, and
        // a tempo-synced eighth-note vocal delay only in Worship. Delay time locks to the
        // detected tempo when confident; otherwise a sane fixed fallback.
        const float bpm = bpm_.load(std::memory_order_relaxed);
        const float conf = bpmConfidence_.load(std::memory_order_relaxed);
        const bool haveTempo = conf > 0.4f && bpm >= 60.0f && bpm <= 180.0f;
        s.master.delayTimeSeconds = haveTempo ? 0.5f * (60.0f / bpm) : 0.35f;  // eighth
        s.master.delayFeedback = 0.32f;
        switch (scene) {
            case Scene::Worship:
                s.master.reverbDecaySeconds = 1.9f;
                s.master.reverbDamping = 0.28f;
                s.master.delayWetDb = -18.0f;     // subtle, mono-compatible throwback
                break;
            case Scene::Prayer:
                s.master.reverbDecaySeconds = 1.6f;
                s.master.reverbDamping = 0.35f;
                s.master.delayWetDb = -120.0f;    // delay off
                break;
            default:                              // Sermon / Pre / Post: dry & intelligible
                s.master.reverbDecaySeconds = 1.2f;
                s.master.reverbDamping = 0.45f;
                s.master.delayWetDb = -120.0f;
                break;
        }

        int numCh = 0;
        std::array<Cls, EngineSnapshot::kMaxCh> classes{};
        std::array<bdsp::ChannelParams, EngineSnapshot::kMaxCh> manual{};
        std::array<OverrideMask, EngineSnapshot::kMaxCh> masks{};
        {
            std::lock_guard<std::mutex> lk(controlMutex_);
            numCh = numCh_;
            classes = classes_;
            manual = manualParams_;
            masks = overrideMask_;
        }
        s.numCh = numCh;

        for (int i = 0; i < numCh; ++i) {
            // INTEGRATION POINT: classifier label would arrive here (ONNX). For the
            // skeleton we use the soundcheck-assigned class.
            const Cls c = classes[(size_t)i];
            const SourceProfile p = profileFor(c);
            updateMeasurementState(i, c);
            bdsp::ChannelParams cp;
            cp.trimDb = autoTrimDb_[(size_t)i];
            cp.isSpeech = p.isSpeech;
            cp.hpfHz = p.hpfHz;
            cp.gateEnabled = p.gateEnabled;
            cp.gateThreshDb = std::max(
                -60.0f,
                std::min(-15.0f, noiseFloorDb_[(size_t)i] + p.gateOffsetDb)
            );
            cp.gateRatio = p.gateRatio;
            cp.gateRangeDb = p.gateRangeDb;
            cp.compThreshDb = p.compThreshDb;
            cp.compRatio = p.compRatio;
            cp.compAttack = p.compAttack;
            cp.compRelease = p.compRelease;
            cp.compKnee = p.compKnee;
            // INTEGRATION: corrective notch + cross-channel masking carves are computed
            // from the live spectra here (see web/src/brain/autoEq.ts & masking.ts).
            cp.voice = p.voice;
            cp.pan = p.pan * 0.7f;
            const float sceneFader = -3.0f + sceneFaderOffset(scene, p.bus);
            float levelCorrection = 0.0f;
            if (c != Cls::Unknown &&
                activeHoldTicks_[(size_t)i] > 0 &&
                slowPostRmsDb_[(size_t)i] > -99.0f) {
                levelCorrection = std::max(
                    -3.0f,
                    std::min(
                        3.0f,
                        (targetPostRmsDb(c) - slowPostRmsDb_[(size_t)i]) * 0.12f
                    )
                );
            }
            const float faderTarget = std::max(-80.0f, std::min(12.0f, sceneFader + levelCorrection));
            // A 16 dB sermon duck completes in about 1.6 seconds at 20 Hz. Smaller
            // measurement-driven corrections inherit the slow measurement EMA.
            autoFaderDb_[(size_t)i] = approach(autoFaderDb_[(size_t)i], faderTarget, 0.5f);
            cp.faderDb = autoFaderDb_[(size_t)i];
            cp.reverbSendDb = (scene == Scene::Worship && p.bus == bdsp::BusId::Vocals) ? -9.0f : -60.0f;
            applyManual(cp, manual[(size_t)i], masks[(size_t)i]);
            s.ch[i] = cp;
            autoFaderPublished_[(size_t)i].store(autoFaderDb_[(size_t)i], std::memory_order_relaxed);
        }
    }

    static void applyManual(bdsp::ChannelParams& target, const bdsp::ChannelParams& manual, OverrideMask mask) {
        if (mask & OverrideTrim) target.trimDb = manual.trimDb;
        if (mask & OverrideHpf) target.hpfHz = manual.hpfHz;
        if (mask & OverrideGate) {
            target.gateEnabled = manual.gateEnabled;
            target.gateThreshDb = manual.gateThreshDb;
            target.gateRatio = manual.gateRatio;
            target.gateRangeDb = manual.gateRangeDb;
        }
        if (mask & OverrideEq) {
            target.corr = manual.corr;
            target.mask = manual.mask;
            target.voice = manual.voice;
            target.deEss = manual.deEss;
        }
        if (mask & OverrideComp) {
            target.compThreshDb = manual.compThreshDb;
            target.compRatio = manual.compRatio;
            target.compAttack = manual.compAttack;
            target.compRelease = manual.compRelease;
            target.compKnee = manual.compKnee;
            target.compMakeupDb = manual.compMakeupDb;
        }
        if (mask & OverrideFader) target.faderDb = manual.faderDb;
        if (mask & OverridePan) target.pan = manual.pan;
        if (mask & OverrideReverb) target.reverbSendDb = manual.reverbSendDb;
    }

    int numCh_ = 0;
    double fs_ = bdsp::kDefaultSampleRate;
    std::array<Cls, EngineSnapshot::kMaxCh> classes_{};
    std::thread th_;
    std::atomic<bool> running_{false}, frozen_{false}, opBypass_{false}, watchdogBypass_{false};
    std::atomic<int> scene_{(int)Scene::PreService};
    std::atomic<int64_t> lastTickMs_{0};
    std::atomic<uint64_t> publishSeq_{0};
    uint64_t appliedSeq_ = 0; // audio-thread local
    AtomicEngineSnapshot published_;
    std::array<AtomicChannelMeasurement, EngineSnapshot::kMaxCh> measurements_{};
    std::mutex controlMutex_;
    std::array<bdsp::ChannelParams, EngineSnapshot::kMaxCh> manualParams_{};
    std::array<OverrideMask, EngineSnapshot::kMaxCh> overrideMask_{};
    std::array<float, EngineSnapshot::kMaxCh> noiseFloorDb_{};
    std::array<float, EngineSnapshot::kMaxCh> slowInputRmsDb_{};
    std::array<float, EngineSnapshot::kMaxCh> slowPostRmsDb_{};
    std::array<float, EngineSnapshot::kMaxCh> autoTrimDb_{};
    std::array<float, EngineSnapshot::kMaxCh> autoFaderDb_{};
    std::array<int, EngineSnapshot::kMaxCh> activeHoldTicks_{};
    std::array<bool, EngineSnapshot::kMaxCh> haveActiveMeasurement_{};
    std::array<std::atomic<float>, EngineSnapshot::kMaxCh> autoTrimPublished_{};
    std::array<std::atomic<float>, EngineSnapshot::kMaxCh> autoFaderPublished_{};
    std::array<std::atomic<float>, EngineSnapshot::kMaxCh> noiseFloorPublished_{};
    std::array<std::atomic<bool>, EngineSnapshot::kMaxCh> activePublished_{};
    bdsp::BeatTracker beatTracker_;           // brain-thread only
    bdsp::Engine* onsetEngine_ = nullptr;     // onset source, set before start()
    std::atomic<float> bpm_{0.0f};
    std::atomic<float> bpmConfidence_{0.0f};
#if DEBUG
    std::atomic<bool> debugTickPaused_{false};
#endif
};

} // namespace app
