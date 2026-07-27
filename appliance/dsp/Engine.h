// Engine.h - the full deterministic mix engine: channels -> automix (speech) -> buses
// -> master (glue comp -> master EQ -> loudness meter -> true-peak limiter) -> out,
// with an always-available SAFE bypass (curated role-aware mix of raw inputs straight
// to the limiter) so audio never goes silent if anything upstream misbehaves.
//
// This is the audio-thread half of the two-rate design. It allocates only in
// prepare(); process() does no allocation, no locking, no ML.
#pragma once
#include "DspConfig.h"
#include "ChannelStrip.h"
#include "Automixer.h"
#include "Loudness.h"
#include "Limiter.h"
#include "Reverb.h"
#include "TempoDelay.h"
#include "OnsetDetector.h"
#include "Params.h"
#include "Smoothed.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

namespace bdsp {

enum class BusId { Drums, Band, Vocals, Speech };

class Engine {
public:
    void prepare(double sampleRate, int maxBlock, int numChannels) {
        fs_ = sampleRate;
        maxBlock_ = maxBlock;
        strips_.resize(numChannels);
        pan_.resize(numChannels);
        send_.resize(numChannels);
        bus_.assign(numChannels, BusId::Band);
        speech_.assign(numChannels, false);
        safeLeftGain_.assign(numChannels, dbToGain(-24.0f) * 0.7071f);
        safeRightGain_.assign(numChannels, dbToGain(-24.0f) * 0.7071f);
        chBuf_.assign(numChannels, std::vector<float>(maxBlock, 0.0f));
        channelPostRmsDb_.assign(numChannels, -100.0f);
        speechBuf_.assign(maxBlock, 0.0f);
        speechPtrs_.resize(numChannels);
        reverb_.prepare(sampleRate, 1.8f, 0.3f, 1.0f);

        for (int i = 0; i < numChannels; ++i) {
            strips_[i].reset(sampleRate);
            pan_[i].reset(sampleRate, 0.05);
            pan_[i].setImmediate(0.0f);
            send_[i].reset(sampleRate, 0.05);
            send_[i].setImmediate(0.0f);
        }

        reverbReturn_.reset(sampleRate, 0.08);
        reverbReturn_.setImmediate(dbToGain(-12.0f));
        loudnessTrim_.reset(sampleRate, 0.5);
        loudnessTrim_.setImmediate(1.0f);
        delay_.prepare(sampleRate, 2.0f);
        delayWet_.reset(sampleRate, 0.08);
        delayWet_.setImmediate(0.0f);
        onset_.prepare(sampleRate, 200.0);

        automix_.reset(sampleRate, std::max(1, numChannels));
        for (int i = 0; i < numChannels; ++i) automix_.setWeight(i, 0.0f);
        loud_.reset(sampleRate);
        lim_.reset(sampleRate, -1.0f);
        glueEnv_ = 0.0f;
        glueAtk_ = std::exp(-1.0 / (0.03 * fs_));
        glueRel_ = std::exp(-1.0 / (0.25 * fs_));
        eqAirL_.reset(sampleRate);
        eqAirR_.reset(sampleRate);
        eqAirL_.set(SVF::HighShelf, 12000.0, 0.7, 1.0);
        eqAirR_.set(SVF::HighShelf, 12000.0, 0.7, 1.0);
        recomputeSafeNormalization();
    }

    void setChannelConfig(
        int i,
        BusId bus,
        bool isSpeech,
        float safeGainDb = -18.0f,
        float safePan = 0.0f
    ) {
        if (i < 0 || i >= (int)strips_.size()) return;
        bus_[i] = bus;
        speech_[i] = isSpeech;
        automix_.setWeight(i, isSpeech ? 1.0f : 0.0f);
        const float gain = dbToGain(std::max(-60.0f, std::min(6.0f, safeGainDb)));
        const float pan = std::max(-1.0f, std::min(1.0f, safePan));
        const float angle = (pan * 0.5f + 0.5f) * 1.5707963f;
        safeLeftGain_[(size_t)i] = gain * std::cos(angle);
        safeRightGain_[(size_t)i] = gain * std::sin(angle);
        recomputeSafeNormalization();
    }

    void setChannelParams(int i, const ChannelParams& p) {
        if (i < 0 || i >= (int)strips_.size()) return;
        strips_[i].setParams(p);
        pan_[i].setTarget(p.pan);
        send_[i].setTarget(p.reverbSendDb <= -50.0f ? 0.0f : dbToGain(p.reverbSendDb));
    }

    void setMasterParams(const MasterParams& m) {
        glueThresh_ = m.glueThreshDb;
        glueRatio_ = std::max(1.0f, m.glueRatio);
        lim_.setCeiling(m.ceilingDbTP);
        targetLufs_ = m.targetLufs;
        loudnessTrim_.setTarget(dbToGain(std::max(-6.0f, std::min(6.0f, m.loudnessTrimDb))));
        reverbReturn_.setTarget(m.reverbReturnDb <= -50.0f ? 0.0f : dbToGain(m.reverbReturnDb));
        reverb_.setDecay(m.reverbDecaySeconds);
        reverb_.setDamping(m.reverbDamping);
        delay_.setTimeSeconds(m.delayTimeSeconds);
        delay_.setFeedback(m.delayFeedback);
        delayWet_.setTarget(m.delayWetDb <= -60.0f ? 0.0f : dbToGain(m.delayWetDb));
    }

    // Drained by the brain thread (control rate) to track tempo. SPSC-safe with the
    // audio thread that produces them; touches nothing else in the engine.
    int drainOnsets(float* dst, int maxN) { return onsetRing_.drain(dst, maxN); }
    double onsetFeatureRate() const { return onset_.featureRate(); }

    void setBypass(bool b) { bypass_ = b; }

    float momentaryLufs() const { return loud_.momentary(); }
    float shortTermLufs() const { return loud_.shortTerm(); }
    bool shortTermLoudnessReady() const { return loud_.shortTermReady(); }
    float integratedLufs() const { return loud_.integrated(); }
    float limiterGrDb() const { return lim_.gainReductionDb(); }
    float channelGrDb(int i) const { return strips_[i].compGainReductionDb(); }
    float channelPostRmsDb(int i) const {
        return i >= 0 && i < (int)channelPostRmsDb_.size()
            ? channelPostRmsDb_[(size_t)i]
            : -100.0f;
    }

    // inputs: numChannels mono buffers; out: stereo
    void process(const float* const* inputs, int numCh, float* outL, float* outR, int frames) {
        numCh = std::min(numCh, (int)strips_.size());
        frames = std::min(frames, maxBlock_);

        // 1) per-channel strips into scratch buffers
        for (int i = 0; i < (int)strips_.size(); ++i) {
            float* cb = chBuf_[i].data();
            double sumSquares = 0.0;
            if (i < numCh) {
                const float* in = inputs[i];
                for (int s = 0; s < frames; ++s) {
                    const float sample = strips_[i].process(in[s]);
                    cb[s] = sample;
                    sumSquares += (double)sample * sample;
                }
            } else {
                std::fill(cb, cb + frames, 0.0f);
            }
            const double rms = frames > 0 ? std::sqrt(sumSquares / frames) : 0.0;
            channelPostRmsDb_[(size_t)i] = rms > 1e-7
                ? (float)(20.0 * std::log10(rms))
                : -100.0f;
            speechPtrs_[i] = cb;
        }

        // 2) speech automix
        if (!speechPtrs_.empty()) automix_.process(speechPtrs_.data(), speechBuf_.data(), frames);
        else std::fill(speechBuf_.begin(), speechBuf_.begin() + frames, 0.0f);

        // 3) sum buses -> master, then glue/EQ/loudness/limiter (or SAFE bypass)
        for (int s = 0; s < frames; ++s) {
            float busL[4] = {0.0f, 0.0f, 0.0f, 0.0f};
            float busR[4] = {0.0f, 0.0f, 0.0f, 0.0f};
            float safeL = 0.0f;
            float safeR = 0.0f;
            float reverbSend = 0.0f;

            for (int i = 0; i < numCh; ++i) {
                safeL += inputs[i][s] * safeLeftGain_[(size_t)i];
                safeR += inputs[i][s] * safeRightGain_[(size_t)i];
                reverbSend += chBuf_[i][s] * send_[i].next();
                if (speech_[i]) continue; // summed via the automix bus below

                const float p = pan_[i].next();
                const float ang = (p * 0.5f + 0.5f) * 1.5707963f; // equal-power
                const int b = busIndex(bus_[i]);
                busL[b] += chBuf_[i][s] * std::cos(ang);
                busR[b] += chBuf_[i][s] * std::sin(ang);
            }

            // speech bus (centered)
            const float spOut = speechBuf_[s] * 0.7071f;
            busL[busIndex(BusId::Speech)] += spOut;
            busR[busIndex(BusId::Speech)] += spOut;

            if (bypass_) {
                // Static, role-aware raw mix straight to the limiter. Energy
                // normalization bounds the nominal contribution as channel count
                // grows; the true-peak limiter still covers coherent worst cases.
                const float safeOutL = safeL * safeNormalization_;
                const float safeOutR = safeR * safeNormalization_;
                feedOnset(std::max(std::fabs(safeOutL), std::fabs(safeOutR)));
                float oL, oR;
                lim_.process(safeOutL, safeOutR, oL, oR);
                loud_.process(oL, oR);
                outL[s] = oL;
                outR[s] = oR;
                continue;
            }

            float rvL = 0.0f, rvR = 0.0f;
            reverb_.process(reverbSend, rvL, rvR);
            const float ret = reverbReturn_.next();
            float L = rvL * ret, R = rvR * ret;
            for (int b = 0; b < 4; ++b) {
                L += busL[b];
                R += busR[b];
            }

            // tempo-synced delay on the vocals bus (wet added back; conservative)
            const float wet = delayWet_.next();
            const int vb = busIndex(BusId::Vocals);
            const float vocalMono = 0.5f * (busL[vb] + busR[vb]);
            float dL = 0.0f, dR = 0.0f;
            delay_.process(vocalMono, dL, dR);
            L += dL * wet;
            R += dR * wet;

            // stereo-linked glue compressor
            const float det = std::max(std::fabs(L), std::fabs(R));
            const float a = det > glueEnv_ ? glueAtk_ : glueRel_;
            glueEnv_ = a * glueEnv_ + (1.0f - a) * det;
            const float lvlDb = glueEnv_ > 1e-7f ? 20.0f * std::log10(glueEnv_) : -140.0f;
            float grDb = 0.0f;
            if (lvlDb > glueThresh_) grDb = (1.0f - 1.0f / glueRatio_) * (lvlDb - glueThresh_);
            const float gg = dbToGain(-grDb);
            L *= gg;
            R *= gg;

            // master air EQ
            L = eqAirL_.process(L);
            R = eqAirR_.process(R);

            feedOnset(std::max(std::fabs(L), std::fabs(R)));   // tempo feature pre-limiter

            // Slow loudness normalization sits after tone/dynamics and before both
            // the meter and final safety limiter. SAFE bypass intentionally skips it.
            const float loudnessGain = loudnessTrim_.next();
            L *= loudnessGain;
            R *= loudnessGain;

            // loudness metering (post-trim, pre-limiter) + true-peak limiter
            loud_.process(L, R);
            float oL, oR;
            lim_.process(L, R, oL, oR);
            outL[s] = oL;
            outR[s] = oR;
        }
    }

private:
    static int busIndex(BusId bus) {
        switch (bus) {
            case BusId::Drums: return 0;
            case BusId::Band: return 1;
            case BusId::Vocals: return 2;
            case BusId::Speech: return 3;
        }
        return 1;
    }

    void feedOnset(float mixMag) {
        float onset = 0.0f;
        if (onset_.process(mixMag, onset)) onsetRing_.push(onset);
    }

    void recomputeSafeNormalization() {
        double energy = 0.0;
        for (size_t i = 0; i < safeLeftGain_.size(); ++i) {
            energy += (double)safeLeftGain_[i] * safeLeftGain_[i];
            energy += (double)safeRightGain_[i] * safeRightGain_[i];
        }
        safeNormalization_ = energy > 1.0 ? (float)(1.0 / std::sqrt(energy)) : 1.0f;
    }

    double fs_ = kDefaultSampleRate;
    int maxBlock_ = 512;
    std::vector<ChannelStrip> strips_;
    std::vector<Smoothed> pan_, send_;
    std::vector<BusId> bus_;
    std::vector<bool> speech_;
    std::vector<float> safeLeftGain_, safeRightGain_;
    std::vector<std::vector<float>> chBuf_;
    std::vector<float> channelPostRmsDb_;
    std::vector<float> speechBuf_;
    std::vector<const float*> speechPtrs_;
    Automixer automix_;
    Loudness loud_;
    Limiter lim_;
    SVF eqAirL_, eqAirR_;
    Smoothed reverbReturn_;
    Smoothed loudnessTrim_;
    Reverb reverb_;
    TempoDelay delay_;
    Smoothed delayWet_;
    OnsetDetector onset_;
    SpscFloatRing<1024> onsetRing_;
    float glueEnv_ = 0, glueAtk_ = 0, glueRel_ = 0, glueThresh_ = -18, glueRatio_ = 2;
    float targetLufs_ = -14;
    float safeNormalization_ = 1.0f;
    bool bypass_ = false;
};

} // namespace bdsp
