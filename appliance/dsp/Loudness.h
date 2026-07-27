// Loudness.h — ITU-R BS.1770 / EBU R128 loudness measurement: momentary (400 ms),
// short-term (3 s), and gated integrated LUFS. Stereo. Feeds the master loudness
// readout that targets ~ -14 LUFS for streaming.
#pragma once
#include "DspConfig.h"
#include "Biquad.h"
#include <array>
#include <cmath>
#include <algorithm>

namespace bdsp {

class Loudness {
public:
    void reset(double sampleRate) {
        fs_ = sampleRate;
        kL_.reset(sampleRate); kR_.reset(sampleRate);
        block100_ = (int)std::round(0.1 * fs_);
        accL_ = accR_ = 0.0; accN_ = 0;
        histCount_ = histWrite_ = 0;
        intCount_ = intWrite_ = 0;
    }

    inline void process(float l, float r) {
        const double yl = kL_.process(l);
        const double yr = kR_.process(r);
        accL_ += yl * yl;
        accR_ += yr * yr;
        if (++accN_ >= block100_) pushBlock();
    }

    float momentary() const { return meanLufs(4); }
    float shortTerm() const { return meanLufs(30); }
    bool shortTermReady() const { return histCount_ >= 30; }
    float integrated() const {
        if (intCount_ == 0) return -100.0f;
        double sum = 0;
        for (int i = 0; i < intCount_; ++i) sum += intBlockAt(i);
        const double meanAll = sum / intCount_;
        const double relGate = -0.691 + 10.0 * std::log10(meanAll) - 10.0;
        double g = 0; int c = 0;
        for (int i = 0; i < intCount_; ++i) {
            const double v = intBlockAt(i);
            const double l = -0.691 + 10.0 * std::log10(v);
            if (l >= relGate) { g += v; ++c; }
        }
        return c ? (float)(-0.691 + 10.0 * std::log10(g / c)) : -100.0f;
    }
    void resetIntegrated() { intCount_ = intWrite_ = 0; }

private:
    static constexpr int kHistBlocks = 30;
    static constexpr int kMaxIntBlocks = 18000; // ~30 min of 100 ms blocks

    void pushBlock() {
        const int n = accN_ ? accN_ : 1;
        const double msL = accL_ / n, msR = accR_ / n;
        hist_[histWrite_] = {msL, msR};
        histWrite_ = (histWrite_ + 1) % kHistBlocks;
        histCount_ = std::min(histCount_ + 1, kHistBlocks);
        // momentary (last 4 blocks = 400 ms) feeds the gated integrated history
        const int m = std::min(histCount_, 4);
        double sL = 0, sR = 0;
        for (int i = histCount_ - m; i < histCount_; ++i) { const auto h = histAt(i); sL += h.l; sR += h.r; }
        const double momMs = sL / m + sR / m;
        if (momMs > 0) {
            const double momLufs = -0.691 + 10.0 * std::log10(momMs);
            if (momLufs > -70.0) {
                intBlocks_[intWrite_] = momMs;
                intWrite_ = (intWrite_ + 1) % kMaxIntBlocks;
                intCount_ = std::min(intCount_ + 1, kMaxIntBlocks);
            }
        }
        accL_ = accR_ = 0.0; accN_ = 0;
    }
    float meanLufs(int blocks) const {
        const int m = std::min(histCount_, blocks);
        if (m <= 0) return -100.0f;
        double sL = 0, sR = 0;
        for (int i = histCount_ - m; i < histCount_; ++i) { const auto h = histAt(i); sL += h.l; sR += h.r; }
        const double ms = sL / m + sR / m;
        return ms > 0 ? (float)(-0.691 + 10.0 * std::log10(ms)) : -100.0f;
    }

    struct MS { double l, r; };
    MS histAt(int offsetFromOldest) const {
        const int oldest = (histWrite_ - histCount_ + kHistBlocks) % kHistBlocks;
        return hist_[(oldest + offsetFromOldest) % kHistBlocks];
    }
    double intBlockAt(int offsetFromOldest) const {
        const int oldest = (intWrite_ - intCount_ + kMaxIntBlocks) % kMaxIntBlocks;
        return intBlocks_[(oldest + offsetFromOldest) % kMaxIntBlocks];
    }

    double fs_ = kDefaultSampleRate;
    KWeighting kL_, kR_;
    int block100_ = 9600, accN_ = 0;
    double accL_ = 0, accR_ = 0;
    std::array<MS, kHistBlocks> hist_{};
    std::array<double, kMaxIntBlocks> intBlocks_{};
    int histCount_ = 0, histWrite_ = 0;
    int intCount_ = 0, intWrite_ = 0;
};

} // namespace bdsp
