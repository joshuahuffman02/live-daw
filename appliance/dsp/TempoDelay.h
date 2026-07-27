// TempoDelay.h — stereo ping-pong delay whose time can be locked to the detected
// tempo. Conservative "production" effect: feedback is hard-clamped so the line can
// never run away on a live stream, and the brain (not the audio thread) sets the time
// from BeatTracker's BPM. Mono send in, stereo wet out; the caller mixes the wet
// signal back at a per-scene level. No allocation after prepare().
#pragma once
#include <vector>
#include <cmath>
#include <algorithm>

namespace bdsp {

class TempoDelay {
public:
    void prepare(double sampleRate, float maxSeconds = 2.0f) {
        fs_ = sampleRate > 0.0 ? sampleRate : 48000.0;
        maxLen_ = std::max(2, (int)std::lround(maxSeconds * fs_));
        bufL_.assign((size_t)maxLen_, 0.0f);
        bufR_.assign((size_t)maxLen_, 0.0f);
        writePos_ = 0;
        setTimeSeconds(0.25f);
        feedback_ = 0.4f;
    }

    void reset() {
        std::fill(bufL_.begin(), bufL_.end(), 0.0f);
        std::fill(bufR_.begin(), bufR_.end(), 0.0f);
        writePos_ = 0;
    }

    void setTimeSeconds(float seconds) {
        const int s = (int)std::lround((double)seconds * fs_);
        delaySamples_ = std::min(maxLen_ - 1, std::max(1, s));
    }

    // division is a fraction of a quarter note: 1.0 = quarter, 0.5 = eighth,
    // 0.75 = dotted eighth, 0.25 = sixteenth.
    void setTempo(float bpm, float division) {
        if (bpm <= 0.0f) return;
        const float quarter = 60.0f / bpm;
        setTimeSeconds(std::max(0.0f, division) * quarter);
    }

    void setFeedback(float fb) {
        feedback_ = std::clamp(fb, 0.0f, 0.85f);   // never allow runaway
    }

    void process(float in, float& outL, float& outR) {
        int rd = writePos_ - delaySamples_;
        if (rd < 0) rd += maxLen_;
        const float readL = bufL_[(size_t)rd];
        const float readR = bufR_[(size_t)rd];

        // Ping-pong: input enters L, bounces L->R->L with decaying feedback.
        float wL = in + feedback_ * readR;
        float wR = feedback_ * readL;
        if (!std::isfinite(wL)) wL = 0.0f;
        if (!std::isfinite(wR)) wR = 0.0f;
        bufL_[(size_t)writePos_] = wL;
        bufR_[(size_t)writePos_] = wR;
        writePos_ = (writePos_ + 1) % maxLen_;

        outL = readL;
        outR = readR;
    }

private:
    double fs_ = 48000.0;
    int maxLen_ = 96000;
    int writePos_ = 0;
    int delaySamples_ = 12000;
    float feedback_ = 0.4f;
    std::vector<float> bufL_;
    std::vector<float> bufR_;
};

} // namespace bdsp
