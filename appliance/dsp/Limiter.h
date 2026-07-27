// Limiter.h — true-peak look-ahead brickwall limiter for the master bus. 4x
// oversampled peak detection (so inter-sample peaks are caught), a short look-ahead
// so gain is reduced *before* the peak arrives (transparent), and a final hard clamp
// that guarantees the ceiling is never exceeded. Broadcast-only latency headroom is
// what makes the look-ahead free. Stereo.
#pragma once
#include "DspConfig.h"
#include <vector>
#include <array>
#include <cmath>
#include <algorithm>

namespace bdsp {

class Limiter {
    static constexpr int kPhases = 4;
    static constexpr int kTaps = 8;

public:
    void reset(double sampleRate, float ceilingDb = -1.0f) {
        fs_ = sampleRate;
        setCeiling(ceilingDb);
        buildOversampler();
        look_ = std::max(8, (int)std::round(0.0015 * fs_));
        dlL_.assign(look_, 0.0f);
        dlR_.assign(look_, 0.0f);
        pos_ = 0;
        gain_ = 1.0f;
        gAtk_ = std::exp(-1.0 / (0.0015 * fs_));
        gRel_ = std::exp(-1.0 / (0.060 * fs_));
        histL_.fill(0.0f); histR_.fill(0.0f);
        grDb_ = 0.0f;
    }
    void setCeiling(float db) { ceilingDb_ = db; ceiling_ = std::pow(10.0f, db / 20.0f); }
    float gainReductionDb() const { return grDb_; }
    int latencySamples() const { return look_; }

    inline void process(float inL, float inR, float& outL, float& outR) {
        const float tp = std::max(truePeak(histL_, inL), truePeak(histR_, inR));
        float gTarget = 1.0f;
        if (tp > ceiling_) gTarget = ceiling_ / tp;
        const float c = gTarget < gain_ ? gAtk_ : gRel_;
        gain_ = c * gain_ + (1.0f - c) * gTarget;
        grDb_ = 20.0f * std::log10(std::max(1e-6f, gain_));

        const float dL = dlL_[pos_], dR = dlR_[pos_];
        dlL_[pos_] = inL; dlR_[pos_] = inR;
        pos_ = (pos_ + 1) % look_;

        outL = clamp(dL * gain_);
        outR = clamp(dR * gain_);
    }

private:
    inline float clamp(float x) const { return std::max(-ceiling_, std::min(ceiling_, x)); }

    void buildOversampler() {
        for (int p = 0; p < kPhases; ++p) {
            double sum = 0;
            for (int t = 0; t < kTaps; ++t) {
                const double x = (t - kTaps / 2 + 1) - (double)p / kPhases;
                const double sinc = (x == 0.0) ? 1.0 : std::sin(M_PI * x) / (M_PI * x);
                const double w = 0.54 - 0.46 * std::cos((2.0 * M_PI * (t + 0.5)) / kTaps);
                ker_[p][t] = sinc * w;
                sum += ker_[p][t];
            }
            for (int t = 0; t < kTaps; ++t) ker_[p][t] /= sum;
        }
    }
    inline float truePeak(std::array<float, kTaps>& hist, float x) {
        for (int i = kTaps - 1; i > 0; --i) hist[i] = hist[i - 1];
        hist[0] = x;
        float mx = std::fabs(x);
        for (int p = 0; p < kPhases; ++p) {
            float y = 0.0f;
            for (int t = 0; t < kTaps; ++t) y += ker_[p][t] * hist[t];
            mx = std::max(mx, std::fabs(y));
        }
        return mx;
    }

    double fs_ = kDefaultSampleRate;
    float ceilingDb_ = -1.0f, ceiling_ = 0.891f;
    float ker_[kPhases][kTaps] = {};
    std::array<float, kTaps> histL_{}, histR_{};
    std::vector<float> dlL_, dlR_;
    int look_ = 144, pos_ = 0;
    float gain_ = 1.0f, gAtk_ = 0, gRel_ = 0, grDb_ = 0;
};

} // namespace bdsp
