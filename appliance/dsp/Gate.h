// Gate.h — downward expander / noise gate with hysteresis and hold. Speech mics use
// gentle expansion (the automixer does the real work); drums/instruments use harder
// gating. Threshold is set by the brain from each channel's measured noise floor.
#pragma once
#include "DspConfig.h"
#include <cmath>
#include <algorithm>

namespace bdsp {

class Gate {
public:
    void reset(double sampleRate) {
        fs_ = sampleRate; env_ = 0; gain_ = 1; open_ = false; hold_ = 0;
        detAtk_ = std::exp(-1.0 / (0.001 * fs_));
        detRel_ = std::exp(-1.0 / (0.05 * fs_));
        atk_ = std::exp(-1.0 / (0.003 * fs_));
        rel_ = std::exp(-1.0 / (0.12 * fs_));
    }
    void setParams(bool enabled, float thresholdDb, float ratio, float rangeDb,
                   float hystDb = 6.0f, float holdS = 0.08f) {
        enabled_ = enabled;
        threshold_ = thresholdDb;
        ratio_ = std::max(1.0f, ratio);
        range_ = std::max(0.0f, rangeDb);
        hyst_ = hystDb;
        holdSamples_ = (int)(holdS * fs_);
    }
    bool isOpen() const { return open_; }
    float gain() const { return gain_; }

    inline float process(float x) {
        if (!enabled_) return x;
        const float rect = std::fabs(x);
        const float a = rect > env_ ? detAtk_ : detRel_;
        env_ = a * env_ + (1.0f - a) * rect;
        const float openThr = dbToGain_(threshold_);
        const float closeThr = dbToGain_(threshold_ - hyst_);
        if (env_ > openThr) { open_ = true; hold_ = holdSamples_; }
        else if (env_ < closeThr) { if (hold_ > 0) --hold_; else open_ = false; }

        float target;
        if (open_) {
            target = 1.0f;
        } else {
            const float envDb = env_ > 1e-9f ? 20.0f * std::log10(env_) : -120.0f;
            const float below = threshold_ - envDb;
            const float redDb = -std::min(range_, below * (ratio_ - 1.0f));
            target = std::max(dbToGain_(-range_), dbToGain_(redDb));
        }
        const float g = target < gain_ ? rel_ : atk_;
        gain_ = g * gain_ + (1.0f - g) * target;
        return x * gain_;
    }

private:
    static inline float dbToGain_(float db) { return std::pow(10.0f, db * 0.05f); }
    double fs_ = kDefaultSampleRate;
    bool enabled_ = false, open_ = false;
    float threshold_ = -45, ratio_ = 2.5f, range_ = 18, hyst_ = 6;
    int holdSamples_ = 0, hold_ = 0;
    float env_ = 0, gain_ = 1;
    float detAtk_ = 0, detRel_ = 0, atk_ = 0, rel_ = 0;
};

} // namespace bdsp
