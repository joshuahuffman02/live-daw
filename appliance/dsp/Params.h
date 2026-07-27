// Params.h — the parameter targets the BRAIN sets at control rate and the audio
// thread consumes. Mirrors the channel strip in the spec. The brain only ever writes
// these; the audio thread only ever reads them (and ramps smoothly toward them).
#pragma once
#include "SVF.h"
#include <array>

namespace bdsp {

struct EqBandParam {
    SVF::Type type = SVF::Bell;
    float freq = 1000.0f;
    float q = 1.0f;
    float gainDb = 0.0f;
};

struct ChannelParams {
    float trimDb = 0.0f;
    float hpfHz = 80.0f;

    bool gateEnabled = false;
    float gateThreshDb = -45.0f, gateRatio = 2.5f, gateRangeDb = 14.0f;

    std::array<EqBandParam, 2> corr{};   // corrective notches (data-driven)
    std::array<EqBandParam, 2> mask{};   // cross-channel masking carves
    std::array<EqBandParam, 3> voice{};  // tonal voicing toward target curve
    EqBandParam deEss{SVF::HighShelf, 7000.0f, 0.8f, 0.0f};

    float compThreshDb = -24.0f, compRatio = 2.5f, compAttack = 0.01f,
          compRelease = 0.2f, compKnee = 8.0f, compMakeupDb = 0.0f;

    float faderDb = -6.0f, pan = 0.0f, reverbSendDb = -60.0f;
    bool isSpeech = false;
};

struct MasterParams {
    float glueThreshDb = -18.0f, glueRatio = 2.0f;
    float targetLufs = -14.0f, ceilingDbTP = -1.0f;
    // Slow control-rate loudness correction. The engine smooths this again before
    // the loudness meter/limiter, so target changes cannot become gain steps.
    float loudnessTrimDb = 0.0f;
    float reverbReturnDb = -12.0f;
    float reverbDecaySeconds = 1.8f, reverbDamping = 0.3f;
    // Tempo-synced vocal delay. Wet defaults to off; the brain sets the time from the
    // detected tempo. Feedback is additionally hard-clamped inside TempoDelay.
    float delayWetDb = -120.0f, delayTimeSeconds = 0.35f, delayFeedback = 0.35f;
};

} // namespace bdsp
