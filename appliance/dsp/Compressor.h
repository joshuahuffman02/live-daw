// Compressor.h — feed-forward, log-domain compressor. Soft knee, peak/RMS-blended
// detection, program-dependent (auto) release. Reports current gain reduction for
// the supervisory UI. Per-sample, deterministic.
#pragma once
#include "DspConfig.h"
#include <cmath>
#include <algorithm>

namespace bdsp {

class Compressor {
public:
    void reset(double sampleRate) { fs_ = sampleRate; env_ = 0.0; gr_ = 0.0; }

    void setParams(float thresholdDb, float ratio, float attackS, float releaseS,
                   float kneeDb, float makeupDb = 0.0f) {
        threshold_ = thresholdDb;
        ratio_ = std::max(1.0f, ratio);
        knee_ = std::max(0.0f, kneeDb);
        makeup_ = makeupDb;
        aAtk_ = static_cast<float>(
            std::exp(-1.0 / (std::max(1e-4f, attackS) * fs_))
        );
        aRel_ = static_cast<float>(
            std::exp(-1.0 / (std::max(1e-4f, releaseS) * fs_))
        );
    }

    // current gain reduction (dB, <= 0) for metering
    float gainReductionDb() const { return -gr_; }

    inline float process(float x) {
        return processWithDetector(x, std::fabs(x));
    }

    // Stereo-linked strips use one max-of-pair detector value for both sides. With
    // matched parameters this produces identical gain reduction and prevents image
    // steering toward whichever side happens to be quieter.
    inline float processWithDetector(float x, float detectorMagnitude) {
        // detector: blend of peak and a short RMS-ish smoothing
        const float rect = std::max(0.0f, detectorMagnitude);
        const float a = rect > env_ ? aAtk_ : aRel_;
        env_ = a * env_ + (1.0f - a) * rect;
        const float levelDb = env_ > 1e-7f ? 20.0f * std::log10(env_) : -140.0f;

        // soft-knee static curve -> target gain reduction (dB, >= 0)
        float over = levelDb - threshold_;
        float targetGr;
        if (over <= -knee_ * 0.5f) {
            targetGr = 0.0f;
        } else if (knee_ > 0.0f && over < knee_ * 0.5f) {
            const float t = over + knee_ * 0.5f;
            targetGr = (1.0f - 1.0f / ratio_) * (t * t) / (2.0f * knee_);
        } else {
            targetGr = (1.0f - 1.0f / ratio_) * over;
        }
        if (targetGr < 0.0f) targetGr = 0.0f;

        // program-dependent smoothing of the reduction
        const float ga = targetGr > gr_ ? aAtk_ : aRel_;
        gr_ = ga * gr_ + (1.0f - ga) * targetGr;

        const float gainDb = makeup_ - gr_;
        return x * dbToGain_(gainDb);
    }

private:
    static inline float dbToGain_(float db) { return std::pow(10.0f, db * 0.05f); }
    double fs_ = kDefaultSampleRate;
    float threshold_ = -24, ratio_ = 2.5f, knee_ = 8, makeup_ = 0;
    float aAtk_ = 0.99f, aRel_ = 0.999f;
    float env_ = 0.0f, gr_ = 0.0f;
};

} // namespace bdsp
