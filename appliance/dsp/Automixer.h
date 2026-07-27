// Automixer.h - Dugan-style gain-sharing automixer. For N open speech mics the shared
// gains sum toward unity, so when one person talks their mic comes up and the others
// duck proportionally; the room tone / noise floor stays constant with none of the
// on/off artifacts of gating. The single highest-value autonomous behaviour for
// spoken word. Deterministic per-sample.
#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

namespace bdsp {

class Automixer {
public:
    void reset(double sampleRate, int channels) {
        n_ = static_cast<size_t>(std::max(0, channels));
        fs_ = std::max(1.0, sampleRate);
        env_.assign(n_, 0.0f);
        gain_.assign(n_, 1.0f / static_cast<float>(std::max<size_t>(1, n_)));
        weight_.assign(n_, 1.0f);
        target_.assign(n_, 0.0f);
        gSmooth_ = static_cast<float>(std::exp(-1.0 / (0.008 * fs_)));
    }
    void setWeight(int i, float w) {
        if (isValidIndex(i)) weight_[static_cast<size_t>(i)] = w;
    }
    void setDepth(float d) { depth_ = std::clamp(d, 0.0f, 1.0f); }
    float gain(int i) const {
        return isValidIndex(i) ? gain_[static_cast<size_t>(i)] : 0.0f;
    }

    // process one block: inputs[i] is channel i's buffer (length frames); writes the
    // summed automixed output into `out`.
    void process(const float* const* inputs, float* out, int frames) {
        if (frames <= 0) return;

        // The detector is updated once per block, so its coefficients must describe
        // the duration of this block. Using per-sample coefficients here makes a
        // nominal 5 ms attack take seconds at normal Core Audio block sizes.
        const float blockAttack = (float)std::exp(-(double)frames / (attackSeconds_ * fs_));
        const float blockRelease = (float)std::exp(-(double)frames / (releaseSeconds_ * fs_));

        // update per-channel power envelopes from this block
        for (size_t i = 0; i < n_; ++i) {
            double p = 0.0;
            const float* in = inputs[i];
            for (int s = 0; s < frames; ++s) p += (double)in[s] * in[s];
            p /= std::max(1, frames);
            const float a = p > env_[i] ? blockAttack : blockRelease;
            env_[i] = a * env_[i] + (1.0f - a) * (float)p;
        }

        // gain-sharing weights
        double total = floor_;
        for (size_t i = 0; i < n_; ++i) total += weight_[i] * env_[i];
        int active = 0;
        for (size_t i = 0; i < n_; ++i) if (weight_[i] > 0) ++active;
        active = std::max(1, active);
        for (size_t i = 0; i < n_; ++i) {
            const float share = (float)((weight_[i] * env_[i]) / total);
            const float flat = weight_[i] > 0 ? weight_[i] / active : 0.0f;
            target_[i] = depth_ * share + (1.0f - depth_) * flat;
        }

        // apply, per-sample smoothed
        for (int s = 0; s < frames; ++s) out[s] = 0.0f;
        for (size_t i = 0; i < n_; ++i) {
            float g = gain_[i];
            const float t = target_[i];
            const float* in = inputs[i];
            for (int s = 0; s < frames; ++s) {
                g = gSmooth_ * g + (1.0f - gSmooth_) * t;
                out[s] += g * in[s];
            }
            gain_[i] = g;
        }
    }

private:
    bool isValidIndex(int i) const {
        return i >= 0 && static_cast<size_t>(i) < n_;
    }

    size_t n_ = 0;
    double fs_ = 48000.0;
    std::vector<float> env_, gain_, weight_, target_;
    float depth_ = 1.0f, floor_ = 1e-5f;
    double attackSeconds_ = 0.005, releaseSeconds_ = 0.080;
    float gSmooth_ = 0;
};

} // namespace bdsp
