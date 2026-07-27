// Reverb.h — production-grade stereo feedback-delay-network (FDN) reverb.
// Four delay lines mixed through a lossless Householder matrix, with per-line damping
// and a decay-time-derived feedback gain. Deterministic, no IR files, no allocation
// after prepare(). This replaces the placeholder 64-tap early-reflection reverb; it is
// a clean "production" space, not a creative effect. Mono send in, stereo out.
#pragma once
#include <vector>
#include <array>
#include <cmath>
#include <algorithm>

namespace bdsp {

class Reverb {
public:
    void prepare(double sampleRate,
                 float decaySeconds = 1.8f,
                 float damping = 0.3f,
                 float sizeMul = 1.0f) {
        fs_ = sampleRate > 0.0 ? sampleRate : 48000.0;
        // Mutually detuned line lengths (ms) for a dense, natural tail.
        const float baseMs[kLines] = {29.7f, 37.1f, 41.3f, 43.7f};
        const float clampedSize = std::clamp(sizeMul, 0.25f, 3.0f);
        for (int i = 0; i < kLines; ++i) {
            int len = std::max(1, (int)std::lround(baseMs[i] * clampedSize * 1e-3 * fs_));
            lines_[i].assign((size_t)len, 0.0f);
            pos_[i] = 0;
            lp_[i] = 0.0f;
        }
        setDamping(damping);
        setDecay(decaySeconds);
    }

    void setDecay(float seconds) {
        decaySeconds_ = std::max(0.05f, seconds);
        for (int i = 0; i < kLines; ++i) {
            const double lenSec = (double)lines_[i].size() / fs_;
            // Feedback gain that reaches -60 dB after decaySeconds_ for this line length.
            fb_[i] = (float)std::pow(10.0, -3.0 * lenSec / (double)decaySeconds_);
        }
    }

    void setDamping(float damping) {
        // 0 = bright (no high-frequency loss), ~0.9 = dark tail.
        damping_ = std::clamp(damping, 0.0f, 0.95f);
    }

    void process(float in, float& outL, float& outR) {
        float d[kLines];
        for (int i = 0; i < kLines; ++i) d[i] = lines_[i][(size_t)pos_[i]];

        // Lossless Householder mix: H = I - 0.5 * J (orthogonal for 4 lines).
        const float s = 0.5f * (d[0] + d[1] + d[2] + d[3]);
        const float a = 1.0f - damping_;   // one-pole low-pass coefficient
        for (int i = 0; i < kLines; ++i) {
            const float mixed = d[i] - s;
            lp_[i] += a * (mixed - lp_[i]);          // damp the tail
            float v = lp_[i] * fb_[i] + in;          // decay + inject the send
            if (!std::isfinite(v)) v = 0.0f;         // hard safety net
            lines_[i][(size_t)pos_[i]] = v;
            pos_[i] = (pos_[i] + 1) % (int)lines_[i].size();
        }

        // Decorrelated stereo taps.
        outL = 0.5f * (d[0] - d[1] + d[2] - d[3]);
        outR = 0.5f * (d[0] + d[1] - d[2] - d[3]);
    }

private:
    static constexpr int kLines = 4;

    double fs_ = 48000.0;
    float decaySeconds_ = 1.8f;
    float damping_ = 0.3f;
    std::array<std::vector<float>, kLines> lines_{};
    std::array<int, kLines> pos_{};
    std::array<float, kLines> lp_{};
    std::array<float, kLines> fb_{};
};

} // namespace bdsp
