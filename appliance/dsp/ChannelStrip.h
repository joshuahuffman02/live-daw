// ChannelStrip.h — composes the per-channel signal chain in the spec's order:
//   trim -> HPF -> gate -> corrective EQ -> masking carve -> compressor
//        -> voicing EQ -> de-ess -> fader
// Outputs post-fader mono; the Engine handles pan, bus routing and reverb sends.
// Parameters are pushed by the brain via setParams() at control rate; trim and fader
// ramp per-sample to avoid zipper.
#pragma once
#include "DspConfig.h"
#include "Params.h"
#include "Smoothed.h"
#include "SVF.h"
#include "Gate.h"
#include "Compressor.h"

namespace bdsp {

class ChannelStrip {
public:
    void reset(double sampleRate) {
        fs_ = sampleRate;
        trim_.reset(sampleRate, 0.05);
        fader_.reset(sampleRate, 0.05);
        trim_.setImmediate(1.0f);
        fader_.setImmediate(dbToGain(-6.0f));
        hpf_.reset(sampleRate);
        for (auto& f : corr_) f.reset(sampleRate);
        for (auto& f : mask_) f.reset(sampleRate);
        for (auto& f : voice_) f.reset(sampleRate);
        deEss_.reset(sampleRate);
        gate_.reset(sampleRate);
        comp_.reset(sampleRate);
        hpf_.set(SVF::HighPass, 80.0, 0.707);
    }

    void setParams(const ChannelParams& p) {
        trim_.setTarget(dbToGain(p.trimDb));
        fader_.setTarget(dbToGain(p.faderDb));
        hpf_.set(SVF::HighPass, p.hpfHz, 0.707);
        for (int i = 0; i < 2; ++i) corr_[i].set(SVF::Bell, p.corr[i].freq, p.corr[i].q, p.corr[i].gainDb);
        for (int i = 0; i < 2; ++i) mask_[i].set(SVF::Bell, p.mask[i].freq, p.mask[i].q, p.mask[i].gainDb);
        for (int i = 0; i < 3; ++i) voice_[i].set(p.voice[i].type, p.voice[i].freq, p.voice[i].q, p.voice[i].gainDb);
        deEss_.set(p.deEss.type, p.deEss.freq, p.deEss.q, p.deEss.gainDb);
        gate_.setParams(p.gateEnabled, p.gateThreshDb, p.gateRatio, p.gateRangeDb);
        comp_.setParams(p.compThreshDb, p.compRatio, p.compAttack, p.compRelease, p.compKnee, p.compMakeupDb);
    }

    inline float process(float in) {
        float x = in * trim_.next();
        x = hpf_.process(x);
        x = gate_.process(x);
        x = corr_[0].process(x);
        x = corr_[1].process(x);
        x = mask_[0].process(x);
        x = mask_[1].process(x);
        x = comp_.process(x);
        x = voice_[0].process(x);
        x = voice_[1].process(x);
        x = voice_[2].process(x);
        x = deEss_.process(x);
        x *= fader_.next();
        return x;
    }

    float compGainReductionDb() const { return comp_.gainReductionDb(); }
    bool gateOpen() const { return gate_.isOpen(); }

private:
    double fs_ = kDefaultSampleRate;
    Smoothed trim_, fader_;
    SVF hpf_;
    SVF corr_[2], mask_[2], voice_[3], deEss_;
    Gate gate_;
    Compressor comp_;
};

} // namespace bdsp
