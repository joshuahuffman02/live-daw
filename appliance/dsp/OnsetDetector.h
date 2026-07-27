// OnsetDetector.h — cheap, allocation-free onset feature for tempo tracking, plus a
// single-producer/single-consumer float ring to hand those features from the audio
// thread to the brain thread. The detector emits one onset-strength sample every
// `hop` input samples (a fixed feature rate independent of the audio block size);
// strength is the positive flux of the per-hop peak magnitude, so transients/accents
// score high and steady tones score ~0. No FFT, no ML, no allocation in process().
#pragma once
#include <array>
#include <atomic>
#include <cmath>
#include <algorithm>

namespace bdsp {

class OnsetDetector {
public:
    void prepare(double sampleRate, double featureRateHz = 200.0) {
        const double fs = sampleRate > 0.0 ? sampleRate : 48000.0;
        hop_ = std::max(1, (int)std::lround(fs / (featureRateHz > 0.0 ? featureRateHz : 200.0)));
        featureRate_ = fs / (double)hop_;
        reset();
    }

    void reset() {
        counter_ = 0;
        peak_ = 0.0f;
        lastPeak_ = 0.0f;
    }

    double featureRate() const { return featureRate_; }

    // Feed one (mono) sample. Returns true and sets `out` when an onset feature is due.
    bool process(float x, float& out) {
        const float a = std::fabs(x);
        if (a > peak_) peak_ = a;
        if (++counter_ >= hop_) {
            counter_ = 0;
            const float flux = peak_ - lastPeak_;
            out = flux > 0.0f ? flux : 0.0f;
            lastPeak_ = peak_;
            peak_ = 0.0f;
            return true;
        }
        return false;
    }

private:
    int hop_ = 240;
    double featureRate_ = 200.0;
    int counter_ = 0;
    float peak_ = 0.0f;
    float lastPeak_ = 0.0f;
};

// Lock-free SPSC ring for onset features: the audio thread pushes, the brain thread
// drains. Fixed storage, no allocation. Drops samples if the consumer falls behind
// (harmless for tempo tracking).
template <int N>
class SpscFloatRing {
public:
    bool push(float v) {
        const uint32_t w = w_.load(std::memory_order_relaxed);
        const uint32_t next = (w + 1) % N;
        if (next == r_.load(std::memory_order_acquire)) return false;  // full
        buf_[w] = v;
        w_.store(next, std::memory_order_release);
        return true;
    }

    int drain(float* dst, int maxN) {
        int c = 0;
        uint32_t r = r_.load(std::memory_order_relaxed);
        while (c < maxN) {
            if (r == w_.load(std::memory_order_acquire)) break;        // empty
            dst[c++] = buf_[r];
            r = (r + 1) % N;
        }
        r_.store(r, std::memory_order_release);
        return c;
    }

private:
    std::array<float, N> buf_{};
    std::atomic<uint32_t> w_{0};
    std::atomic<uint32_t> r_{0};
};

} // namespace bdsp
