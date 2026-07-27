// BeatTracker.h — control-rate tempo estimation from an onset-strength envelope.
// Runs on the BRAIN thread, never on the audio thread. Pure C++/DSP, no ML, no
// allocation after reset(). Autocorrelation of the recent onset envelope picks the
// dominant beat period; BPM + a 0..1 confidence are published for the brain to drive
// a tempo-synced delay and for the UI/telemetry to display.
#pragma once
#include <vector>
#include <cmath>
#include <algorithm>

namespace bdsp {

class BeatTracker {
public:
    void reset(double featureRateHz) {
        fr_ = featureRateHz > 0.0 ? featureRateHz : 200.0;
        windowLen_ = std::max(8, (int)std::lround(fr_ * kWindowSeconds));
        lagMin_ = std::max(1, (int)std::lround(fr_ * 60.0 / kMaxBpm));
        lagMax_ = std::min(windowLen_ - 1, (int)std::lround(fr_ * 60.0 / kMinBpm));
        recomputeInterval_ = std::max(1, (int)std::lround(fr_ * kRecomputeSeconds));
        buf_.assign(windowLen_, 0.0f);
        writePos_ = 0;
        filled_ = 0;
        sinceCompute_ = 0;
        bpm_ = 0.0f;
        confidence_ = 0.0f;
    }

    // One onset-envelope sample at the configured feature rate. Allocation-free.
    void push(float onsetStrength) {
        if (buf_.empty()) return;
        buf_[writePos_] = onsetStrength > 0.0f ? onsetStrength : 0.0f;
        writePos_ = (writePos_ + 1) % windowLen_;
        if (filled_ < windowLen_) ++filled_;
        if (++sinceCompute_ >= recomputeInterval_) {
            sinceCompute_ = 0;
            compute();
        }
    }

    float bpm() const { return bpm_; }
    float confidence() const { return confidence_; }

private:
    static constexpr double kWindowSeconds = 6.0;
    static constexpr double kRecomputeSeconds = 0.25;
    static constexpr double kMinBpm = 60.0;
    static constexpr double kMaxBpm = 180.0;

    double bpmForLag(int lag) const { return 60.0 * fr_ / (double)lag; }

    void compute() {
        const int N = filled_;
        if (N < lagMax_ * 2) {            // not enough history for a stable estimate
            bpm_ = 0.0f;
            confidence_ = 0.0f;
            return;
        }

        // Read the ring oldest -> newest as x(0..N-1).
        auto at = [&](int k) -> float {
            int idx = (writePos_ - N + k) % windowLen_;
            if (idx < 0) idx += windowLen_;
            return buf_[idx];
        };

        double mean = 0.0;
        for (int k = 0; k < N; ++k) mean += at(k);
        mean /= (double)N;

        double r0 = 0.0;
        for (int k = 0; k < N; ++k) {
            const double v = at(k) - mean;
            r0 += v * v;
        }
        if (r0 <= 1e-12) {                // silence / flat envelope
            bpm_ = 0.0f;
            confidence_ = 0.0f;
            return;
        }

        double bestScore = 0.0;
        int bestLag = 0;
        for (int lag = lagMin_; lag <= lagMax_; ++lag) {
            double r = 0.0;
            for (int k = lag; k < N; ++k) {
                r += (at(k) - mean) * (at(k - lag) - mean);
            }
            const double score = r / r0;  // smaller lags keep more overlap, so the
            if (score > bestScore) {      // fundamental period wins over its octaves
                bestScore = score;
                bestLag = lag;
            }
        }

        if (bestLag <= 0) {
            bpm_ = 0.0f;
            confidence_ = 0.0f;
            return;
        }
        bpm_ = (float)bpmForLag(bestLag);
        confidence_ = (float)std::clamp(bestScore, 0.0, 1.0);
    }

    double fr_ = 200.0;
    int windowLen_ = 1200;
    int lagMin_ = 1;
    int lagMax_ = 1;
    int recomputeInterval_ = 50;
    std::vector<float> buf_;
    int writePos_ = 0;
    int filled_ = 0;
    int sinceCompute_ = 0;
    float bpm_ = 0.0f;
    float confidence_ = 0.0f;
};

} // namespace bdsp
