// Main.cpp — headless standalone appliance. Opens the audio device (Dante Virtual
// Soundcard or an RME Digiface Dante present as a Core Audio / ASIO device), runs the
// deterministic bdsp::Engine on the audio thread, and supervises it from the
// control-rate BrainThread. The supervisory UI in the shipping product is remote
// (the web app in ../web is the prototype of it); this binary is the engine + brain.
//
// Build:  cmake -B build && cmake --build build --target BroadcastMixer
// (DSP correctness is covered by the JUCE-free tests: target dsp_tests.)
#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_audio_devices/juce_audio_devices.h>
#include <juce_core/juce_core.h>

#include "Engine.h"
#include "BrainThread.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <vector>

static constexpr double kHD96TargetSampleRate = 96000.0;
static constexpr double kSampleRateToleranceHz = 1.0;

static bool isHD96TargetSampleRate(double sampleRate) {
    return std::abs(sampleRate - kHD96TargetSampleRate) < kSampleRateToleranceHz;
}

class MixerCallback : public juce::AudioIODeviceCallback {
public:
    MixerCallback(app::BrainThread& brain, std::vector<app::Cls> classes)
        : brain_(brain), classes_(std::move(classes)) {}

    bdsp::Engine& engine() { return engine_; }

    void audioDeviceAboutToStart(juce::AudioIODevice* device) override {
        fs_ = device->getCurrentSampleRate();
        block_ = device->getCurrentBufferSizeSamples();
        const int numCh = (int)classes_.size();
        engine_.prepare(fs_, block_, numCh);
        for (int i = 0; i < numCh; ++i) {
            const auto p = app::profileFor(classes_[i]);
            engine_.setChannelConfig(i, p.bus, p.isSpeech);
        }
        inPtrs_.assign(numCh, nullptr);
        silence_.assign(juce::jmax(block_, 2048), 0.0f);
    }

    void audioDeviceIOCallbackWithContext(const float* const* in, int numIn,
                                          float* const* out, int numOut,
                                          int numSamples,
                                          const juce::AudioIODeviceCallbackContext&) override {
        brain_.applyTo(engine_); // pull latest targets (non-blocking)

        const int n = juce::jmin((int)inPtrs_.size(), numIn);
        for (int i = 0; i < n; ++i)
            inPtrs_[i] = (in[i] != nullptr) ? in[i] : silence_.data();
        for (int i = n; i < (int)inPtrs_.size(); ++i)
            inPtrs_[i] = silence_.data();

        if (numOut <= 0 || out[0] == nullptr) return;
        float* outL = out[0];
        float* outR = (numOut > 1 && out[1]) ? out[1] : out[0];
        engine_.process(inPtrs_.data(), (int)inPtrs_.size(), outL, outR, numSamples);

        for (int c = 2; c < numOut; ++c)
            if (out[c]) std::fill(out[c], out[c] + numSamples, 0.0f);
    }

    void audioDeviceStopped() override {}

private:
    app::BrainThread& brain_;
    bdsp::Engine engine_;
    std::vector<app::Cls> classes_;
    std::vector<const float*> inPtrs_;
    std::vector<float> silence_;
    double fs_ = 96000.0;
    int block_ = 256;
};

int main() {
    juce::ScopedJuceInitialiser_GUI juceInit;

    // Soundcheck channel assignment. In the product this comes from the classifier
    // (confirmed by the operator) and the Planning Center plan drives the scene.
    using C = app::Cls;
    std::vector<C> stage = {C::Speech, C::Speech, C::LeadVocal, C::Bgv,
                            C::Acoustic, C::Electric, C::Bass, C::Kick, C::Keys};

    juce::AudioDeviceManager devmgr;
    juce::String err = devmgr.initialiseWithDefaultDevices((int)stage.size(), 2);
    if (err.isNotEmpty()) {
        std::cerr << "Audio init error: " << err << std::endl;
        std::cerr << "Tip: select the Dante Virtual Soundcard / Digiface as the input device.\n";
        return 1;
    }

    auto* dev = devmgr.getCurrentAudioDevice();
    const double fs = dev ? dev->getCurrentSampleRate() : kHD96TargetSampleRate;
    std::cout << "Device: " << (dev ? dev->getName() : juce::String("none"))
              << "  @ " << fs << " Hz, " << (dev ? dev->getCurrentBufferSizeSamples() : 0)
              << " samples\n";
    if (!isHD96TargetSampleRate(fs)) {
        std::cerr << "HD96/Dante target is 96000 Hz. Match the Dante device clock before starting the appliance.\n";
        std::cerr << "Refusing to run at " << fs << " Hz.\n";
        return 2;
    }

    app::BrainThread brain;
    brain.configure((int)stage.size(), fs, stage);
    brain.setScene(app::Scene::Worship); // would be driven by Planning Center
    brain.start();

    MixerCallback cb(brain, stage);
    devmgr.addAudioCallback(&cb);

    std::cout << "AutoMix broadcast engine running.\n"
                 "  FREEZE / SAFE bypass are controlled by the brain + watchdog.\n"
                 "  Press <Enter> to stop.\n";
    std::cin.get();

    devmgr.removeAudioCallback(&cb);
    brain.stop();
    std::cout << "Stopped.\n";
    return 0;
}
