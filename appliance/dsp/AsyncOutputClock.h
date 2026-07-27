#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace bdsp {

// Bounded proportional clock follower for an asynchronous output ring.
//
// Separate Core Audio devices can both report 96 kHz while their physical clocks
// differ by tens or hundreds of ppm. Ring fill then walks monotonically toward an
// underrun or overrun. This controller turns fill error into a small, smoothed
// resampling ratio so the consumer follows the producer without changing the DSP
// engine's clock.
class AsyncOutputClock {
public:
    void prepare(uint64_t targetFillFrames,
                 uint32_t nominalBlockFrames,
                 float maximumCorrectionPpm = 1000.0f) noexcept {
        targetFillFrames_ = std::max<uint64_t>(1, targetFillFrames);
        deadbandFrames_ = std::max<float>(1.0f, (float)nominalBlockFrames * 2.0f);
        maximumCorrectionPpm_ = std::max(1.0f, std::fabs(maximumCorrectionPpm));
        correctionPpm_ = 0.0f;
    }

    void reset() noexcept { correctionPpm_ = 0.0f; }

    float update(uint64_t fillFrames) noexcept {
        if (targetFillFrames_ == 0) return 1.0f;
        const float error =
            (float)((int64_t)fillFrames - (int64_t)targetFillFrames_);
        float requestedPpm = 0.0f;
        if (std::fabs(error) > deadbandFrames_) {
            const float excess =
                error > 0.0f ? error - deadbandFrames_ : error + deadbandFrames_;
            requestedPpm = std::clamp(excess * 2.0f,
                                      -maximumCorrectionPpm_,
                                      maximumCorrectionPpm_);
        }

        // Reject callback-scheduling jitter while converging quickly once fill leaves
        // the two-block deadband.
        correctionPpm_ += 0.02f * (requestedPpm - correctionPpm_);
        if (std::fabs(correctionPpm_) < 0.001f) correctionPpm_ = 0.0f;
        return 1.0f + correctionPpm_ * 1.0e-6f;
    }

    float correctionPpm() const noexcept { return correctionPpm_; }
    uint64_t targetFillFrames() const noexcept { return targetFillFrames_; }
    float maximumCorrectionPpm() const noexcept { return maximumCorrectionPpm_; }

private:
    uint64_t targetFillFrames_ = 1;
    float deadbandFrames_ = 1.0f;
    float maximumCorrectionPpm_ = 1000.0f;
    float correctionPpm_ = 0.0f;
};

} // namespace bdsp
