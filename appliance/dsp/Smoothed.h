// Smoothed.h — one-pole parameter smoother.
// The brain sets a TARGET at control rate; the audio thread ramps to it every
// sample. This is what keeps the spec's "manual override always wins / brain only
// sets targets" model glitch-free. No allocation, no branching in the hot path.
#pragma once
#include <cmath>

namespace bdsp {

class Smoothed {
public:
    void reset(double sampleRate, double seconds = 0.02) {
        // one-pole coefficient for the given time constant
        coeff_ = std::exp(-1.0 / (std::max(1e-5, seconds) * sampleRate));
    }
    void setImmediate(float v) { current_ = target_ = v; }
    void setTarget(float v) { target_ = v; }
    float target() const { return target_; }
    float current() const { return current_; }

    inline float next() {
        current_ = coeff_ * current_ + (1.0f - coeff_) * target_;
        return current_;
    }

private:
    float coeff_ = 0.99f;
    float current_ = 0.0f;
    float target_ = 0.0f;
};

inline float dbToGain(float db) { return std::pow(10.0f, db * 0.05f); }
inline float gainToDb(float g) { return g > 1e-7f ? 20.0f * std::log10(g) : -140.0f; }

} // namespace bdsp
