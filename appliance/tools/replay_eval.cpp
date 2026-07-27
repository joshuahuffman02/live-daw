// Deterministic offline multitrack replay for the production C++ engine/brain.
// It consumes interleaved PCM/float WAV, advances the real 20 Hz control loop from
// audio time (not wall-clock time), writes the rendered program, JSON metrics, and a
// JSONL decision trace suitable for regression comparisons.
#include "../dsp/Engine.h"
#include "../dsp/Loudness.h"
#include "../src/BrainThread.h"
#include "WavIO.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

struct Config {
    std::string inputPath;
    std::string outputPath;
    std::string metricsPath;
    std::string decisionsPath;
    std::vector<app::Cls> roles;
    std::vector<std::pair<int, int>> stereoPairs;
    app::Scene scene = app::Scene::Worship;
    int blockSize = 256;
};

struct Metrics {
    uint32_t sourceCrc32 = 0;
    uint32_t sampleRate = 0;
    uint16_t sourceChannels = 0;
    int inputChannels = 0;
    uint64_t frames = 0;
    uint64_t decisionTicks = 0;
    float outputSamplePeakDbfs = -100.0f;
    float outputIntegratedLufs = -100.0f;
    float outputShortTermLufs = -100.0f;
    float maximumLimiterGrDb = 0.0f;
    float finalAutoLoudnessTrimDb = 0.0f;
    bool outputFinite = true;
    bool inputActive = false;
    bool outputActive = false;
    bool referenceAvailable = false;
    float referenceIntegratedLufs = -100.0f;
    float referenceDeltaLufs = 0.0f;
    bool safetyPassed = false;
};

float amplitudeToDb(double amplitude) {
    return amplitude > 1e-7 ? (float)(20.0 * std::log10(amplitude)) : -100.0f;
}

std::string jsonEscape(const std::string& value) {
    std::ostringstream out;
    for (unsigned char c : value) {
        switch (c) {
            case '"': out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (c < 0x20) {
                    out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                        << (int)c << std::dec << std::setfill(' ');
                } else {
                    out << (char)c;
                }
        }
    }
    return out.str();
}

const char* roleName(app::Cls role) {
    switch (role) {
        case app::Cls::Speech: return "speech";
        case app::Cls::LeadVocal: return "leadVocal";
        case app::Cls::Bgv: return "bgv";
        case app::Cls::Acoustic: return "acousticGuitar";
        case app::Cls::Electric: return "electricGuitar";
        case app::Cls::Bass: return "bass";
        case app::Cls::Kick: return "kick";
        case app::Cls::Snare: return "snare";
        case app::Cls::Tom: return "tom";
        case app::Cls::Overhead: return "overhead";
        case app::Cls::Percussion: return "percussion";
        case app::Cls::Keys: return "keys";
        case app::Cls::Playback: return "playback";
        case app::Cls::Unknown: return "unknown";
    }
    return "unknown";
}

const char* sceneName(app::Scene scene) {
    switch (scene) {
        case app::Scene::PreService: return "preService";
        case app::Scene::Worship: return "worship";
        case app::Scene::Sermon: return "sermon";
        case app::Scene::Prayer: return "prayer";
        case app::Scene::PostService: return "postService";
    }
    return "worship";
}

app::Cls parseRole(const std::string& value) {
    if (value == "speech") return app::Cls::Speech;
    if (value == "leadVocal" || value == "leadvocal") return app::Cls::LeadVocal;
    if (value == "bgv") return app::Cls::Bgv;
    if (value == "acousticGuitar" || value == "acousticguitar") return app::Cls::Acoustic;
    if (value == "electricGuitar" || value == "electricguitar") return app::Cls::Electric;
    if (value == "bass") return app::Cls::Bass;
    if (value == "kick") return app::Cls::Kick;
    if (value == "snare") return app::Cls::Snare;
    if (value == "tom") return app::Cls::Tom;
    if (value == "overhead") return app::Cls::Overhead;
    if (value == "percussion") return app::Cls::Percussion;
    if (value == "keys") return app::Cls::Keys;
    if (value == "playback" || value == "tracks") return app::Cls::Playback;
    if (value == "unknown") return app::Cls::Unknown;
    throw std::runtime_error("unknown role: " + value);
}

app::Scene parseScene(const std::string& value) {
    if (value == "preService" || value == "preservice") return app::Scene::PreService;
    if (value == "worship") return app::Scene::Worship;
    if (value == "sermon") return app::Scene::Sermon;
    if (value == "prayer") return app::Scene::Prayer;
    if (value == "postService" || value == "postservice") return app::Scene::PostService;
    throw std::runtime_error("unknown scene: " + value);
}

std::vector<std::string> split(const std::string& value, char delimiter) {
    std::vector<std::string> fields;
    std::stringstream stream(value);
    std::string field;
    while (std::getline(stream, field, delimiter)) {
        if (!field.empty()) fields.push_back(field);
    }
    return fields;
}

std::vector<std::pair<int, int>> parseStereoPairs(const std::string& value) {
    std::vector<std::pair<int, int>> pairs;
    for (const auto& token : split(value, ',')) {
        const size_t separator = token.find('-');
        if (separator == std::string::npos ||
            token.find('-', separator + 1) != std::string::npos) {
            throw std::runtime_error(
                "stereo pairs must use 1-based adjacent channel numbers such as 11-12,18-19"
            );
        }
        const int left = std::stoi(token.substr(0, separator)) - 1;
        const int right = std::stoi(token.substr(separator + 1)) - 1;
        pairs.emplace_back(left, right);
    }
    return pairs;
}

int stereoPeerFor(const Config& config, int channel) {
    for (const auto& pair : config.stereoPairs) {
        if (pair.first == channel) return pair.second;
        if (pair.second == channel) return pair.first;
    }
    return -1;
}

void writeDecisionRecord(
    std::ostream& out,
    uint64_t tick,
    uint64_t frame,
    uint32_t sampleRate,
    const Config& config,
    const app::BrainThread& brain,
    const std::vector<float>& inputRmsDb,
    const std::vector<float>& inputPeakDb,
    const bdsp::Engine& engine
) {
    out << std::fixed << std::setprecision(4)
        << "{\"tick\":" << tick
        << ",\"frame\":" << frame
        << ",\"seconds\":" << (double)frame / sampleRate
        << ",\"scene\":\"" << sceneName(config.scene) << "\""
        << ",\"master\":{\"momentaryLufs\":" << engine.momentaryLufs()
        << ",\"shortTermLufs\":" << engine.shortTermLufs()
        << ",\"shortTermReady\":" << (engine.shortTermLoudnessReady() ? "true" : "false")
        << ",\"limiterGrDb\":" << engine.limiterGrDb()
        << ",\"autoLoudnessTrimDb\":" << brain.currentAutoLoudnessTrimDb()
        << "},\"channels\":[";
    for (size_t channel = 0; channel < config.roles.size(); ++channel) {
        if (channel) out << ',';
        out << "{\"channel\":" << channel
            << ",\"role\":\"" << roleName(config.roles[channel]) << "\""
            << ",\"stereoPeer\":";
        const int stereoPeer = stereoPeerFor(config, (int)channel);
        if (stereoPeer >= 0) out << stereoPeer + 1;
        else out << "null";
        out
            << ",\"inputRmsDb\":" << inputRmsDb[channel]
            << ",\"inputPeakDb\":" << inputPeakDb[channel]
            << ",\"postRmsDb\":" << engine.channelPostRmsDb((int)channel)
            << ",\"active\":" << (brain.channelActive((int)channel) ? "true" : "false")
            << ",\"noiseFloorDb\":" << brain.currentNoiseFloorDb((int)channel)
            << ",\"autoTrimDb\":" << brain.currentAutoTrimDb((int)channel)
            << ",\"autoFaderDb\":" << brain.currentAutoFaderDb((int)channel)
            << '}';
    }
    out << "]}\n";
}

void writeMetrics(const std::string& path, const Config& config, const Metrics& metrics) {
    std::ofstream out(path, std::ios::trunc);
    if (!out) throw std::runtime_error("could not create metrics JSON: " + path);
    out << std::fixed << std::setprecision(4)
        << "{\n"
        << "  \"schemaVersion\": 2,\n"
        << "  \"input\": \"" << jsonEscape(config.inputPath) << "\",\n"
        << "  \"sourceCrc32\": \"" << std::hex << std::setw(8) << std::setfill('0')
        << metrics.sourceCrc32 << std::dec << std::setfill(' ') << "\",\n"
        << "  \"scene\": \"" << sceneName(config.scene) << "\",\n"
        << "  \"roles\": [";
    for (size_t index = 0; index < config.roles.size(); ++index) {
        if (index) out << ", ";
        out << '"' << roleName(config.roles[index]) << '"';
    }
    out << "],\n"
        << "  \"stereoPairs\": [";
    for (size_t index = 0; index < config.stereoPairs.size(); ++index) {
        if (index) out << ", ";
        out << '[' << config.stereoPairs[index].first + 1
            << ", " << config.stereoPairs[index].second + 1 << ']';
    }
    out << "],\n"
        << "  \"sampleRate\": " << metrics.sampleRate << ",\n"
        << "  \"blockSize\": " << config.blockSize << ",\n"
        << "  \"sourceChannels\": " << metrics.sourceChannels << ",\n"
        << "  \"inputChannels\": " << metrics.inputChannels << ",\n"
        << "  \"frames\": " << metrics.frames << ",\n"
        << "  \"durationSeconds\": " << (double)metrics.frames / metrics.sampleRate << ",\n"
        << "  \"decisionTicks\": " << metrics.decisionTicks << ",\n"
        << "  \"targetLufs\": " << app::sceneTargetLufs(config.scene) << ",\n"
        << "  \"outputSamplePeakDbfs\": " << metrics.outputSamplePeakDbfs << ",\n"
        << "  \"outputIntegratedLufs\": " << metrics.outputIntegratedLufs << ",\n"
        << "  \"outputShortTermLufs\": " << metrics.outputShortTermLufs << ",\n"
        << "  \"maximumLimiterGainReductionDb\": " << metrics.maximumLimiterGrDb << ",\n"
        << "  \"finalAutoLoudnessTrimDb\": " << metrics.finalAutoLoudnessTrimDb << ",\n"
        << "  \"inputActive\": " << (metrics.inputActive ? "true" : "false") << ",\n"
        << "  \"outputActive\": " << (metrics.outputActive ? "true" : "false") << ",\n"
        << "  \"outputFinite\": " << (metrics.outputFinite ? "true" : "false") << ",\n"
        << "  \"referenceAvailable\": " << (metrics.referenceAvailable ? "true" : "false");
    if (metrics.referenceAvailable) {
        out << ",\n"
            << "  \"referenceIntegratedLufs\": " << metrics.referenceIntegratedLufs << ",\n"
            << "  \"referenceDeltaLufs\": " << metrics.referenceDeltaLufs;
    }
    out << ",\n"
        << "  \"safetyPassed\": " << (metrics.safetyPassed ? "true" : "false") << "\n"
        << "}\n";
    if (!out) throw std::runtime_error("failed while writing metrics JSON");
}

Metrics evaluate(const Config& config) {
    const replay::WavData source = replay::readWav(config.inputPath);
    const int inputChannels = (int)config.roles.size();
    if (inputChannels <= 0 || inputChannels > app::EngineSnapshot::kMaxCh) {
        throw std::runtime_error("roles must describe 1..64 input channels");
    }
    const bool hasReference = source.channels == inputChannels + 2;
    if (source.channels != inputChannels && !hasReference) {
        throw std::runtime_error(
            "WAV channels must equal the role count, or role count + stereo reference"
        );
    }
    if (config.blockSize < 16 || config.blockSize > 4096) {
        throw std::runtime_error("block size must be 16..4096 frames");
    }
    std::vector<bool> stereoUsed((size_t)inputChannels, false);
    for (const auto& pair : config.stereoPairs) {
        const int left = pair.first;
        const int right = pair.second;
        if (left < 0 || right != left + 1 || right >= inputChannels) {
            throw std::runtime_error("stereo pairs must be adjacent and within the role list");
        }
        if (stereoUsed[(size_t)left] || stereoUsed[(size_t)right]) {
            throw std::runtime_error("stereo pairs must not overlap");
        }
        if (config.roles[(size_t)left] != config.roles[(size_t)right] ||
            config.roles[(size_t)left] == app::Cls::Speech ||
            config.roles[(size_t)left] == app::Cls::Unknown) {
            throw std::runtime_error("stereo pairs must use the same assigned non-speech role");
        }
        stereoUsed[(size_t)left] = true;
        stereoUsed[(size_t)right] = true;
    }

    std::ofstream decisions(config.decisionsPath, std::ios::trunc);
    if (!decisions) {
        throw std::runtime_error("could not create decision JSONL: " + config.decisionsPath);
    }

    bdsp::Engine engine;
    engine.prepare(source.sampleRate, config.blockSize, inputChannels);
    for (int channel = 0; channel < inputChannels; ++channel) {
        const auto profile = app::profileFor(config.roles[(size_t)channel]);
        engine.setChannelConfig(
            channel,
            profile.bus,
            profile.isSpeech,
            app::safeGainDbFor(config.roles[(size_t)channel]),
            app::safePanFor(config.roles[(size_t)channel])
        );
    }

    app::BrainThread brain;
    brain.configure(inputChannels, source.sampleRate, config.roles);
    brain.setScene(config.scene);
    brain.setOnsetSource(&engine);
    for (const auto& pair : config.stereoPairs) {
        if (!engine.setStereoLink(pair.first, pair.second) ||
            !brain.setStereoLink(pair.first, pair.second)) {
            throw std::runtime_error("could not apply validated stereo pair");
        }
    }

    std::vector<std::vector<float>> planar(
        (size_t)inputChannels,
        std::vector<float>((size_t)config.blockSize, 0.0f)
    );
    std::vector<const float*> inputPointers((size_t)inputChannels, nullptr);
    std::vector<float> inputRmsDb((size_t)inputChannels, -100.0f);
    std::vector<float> inputPeakDb((size_t)inputChannels, -100.0f);
    std::vector<float> outL((size_t)config.blockSize, 0.0f);
    std::vector<float> outR((size_t)config.blockSize, 0.0f);

    replay::WavData program;
    program.sampleRate = source.sampleRate;
    program.channels = 2;
    program.interleaved.resize((size_t)source.frames() * 2u, 0.0f);

    bdsp::Loudness outputLoudness;
    outputLoudness.reset(source.sampleRate);
    bdsp::Loudness referenceLoudness;
    referenceLoudness.reset(source.sampleRate);

    Metrics metrics;
    metrics.sourceCrc32 = replay::crc32File(config.inputPath);
    metrics.sampleRate = source.sampleRate;
    metrics.sourceChannels = source.channels;
    metrics.inputChannels = inputChannels;
    metrics.frames = source.frames();
    metrics.referenceAvailable = hasReference;

    double outputSquares = 0.0;
    uint64_t outputSamples = 0;
    float outputPeak = 0.0f;
    const uint64_t controlInterval = std::max<uint64_t>(1, source.sampleRate / 20u);
    uint64_t nextControlFrame = 0;
    uint64_t tick = 0;

    for (uint64_t frame = 0; frame < source.frames();) {
        const uint64_t framesUntilControl = nextControlFrame > frame
            ? nextControlFrame - frame
            : controlInterval;
        const int framesThisBlock = (int)std::min<uint64_t>(
            (uint64_t)config.blockSize,
            std::min(source.frames() - frame, framesUntilControl)
        );
        for (int channel = 0; channel < inputChannels; ++channel) {
            double squares = 0.0;
            float peak = 0.0f;
            for (int sample = 0; sample < framesThisBlock; ++sample) {
                const float value = source.interleaved[
                    (size_t)(frame + sample) * source.channels + (size_t)channel
                ];
                planar[(size_t)channel][(size_t)sample] = value;
                squares += (double)value * value;
                peak = std::max(peak, std::fabs(value));
            }
            inputPointers[(size_t)channel] = planar[(size_t)channel].data();
            inputRmsDb[(size_t)channel] = amplitudeToDb(
                std::sqrt(squares / std::max(1, framesThisBlock))
            );
            inputPeakDb[(size_t)channel] = amplitudeToDb(peak);
            metrics.inputActive = metrics.inputActive || peak > 1e-5f;
            brain.pushChannelMeasurement(
                channel,
                inputRmsDb[(size_t)channel],
                inputPeakDb[(size_t)channel],
                engine.channelPostRmsDb(channel)
            );
        }
        brain.pushMasterMeasurement(
            engine.shortTermLufs(),
            engine.momentaryLufs(),
            engine.limiterGrDb(),
            engine.shortTermLoudnessReady()
        );

        while (frame >= nextControlFrame) {
            brain.runOneOfflineControlTick();
            brain.applyOfflineTo(engine);
            writeDecisionRecord(
                decisions,
                tick,
                nextControlFrame,
                source.sampleRate,
                config,
                brain,
                inputRmsDb,
                inputPeakDb,
                engine
            );
            ++tick;
            nextControlFrame += controlInterval;
        }
        brain.applyOfflineTo(engine);
        engine.process(
            inputPointers.data(),
            inputChannels,
            outL.data(),
            outR.data(),
            framesThisBlock
        );

        metrics.maximumLimiterGrDb = std::max(metrics.maximumLimiterGrDb, engine.limiterGrDb());
        for (int sample = 0; sample < framesThisBlock; ++sample) {
            const float left = outL[(size_t)sample];
            const float right = outR[(size_t)sample];
            metrics.outputFinite = metrics.outputFinite &&
                std::isfinite(left) && std::isfinite(right);
            outputPeak = std::max(outputPeak, std::max(std::fabs(left), std::fabs(right)));
            outputSquares += (double)left * left + (double)right * right;
            outputSamples += 2;
            outputLoudness.process(left, right);
            program.interleaved[(size_t)(frame + sample) * 2u] = left;
            program.interleaved[(size_t)(frame + sample) * 2u + 1u] = right;

            if (hasReference) {
                const float referenceL = source.interleaved[
                    (size_t)(frame + sample) * source.channels + (size_t)inputChannels
                ];
                const float referenceR = source.interleaved[
                    (size_t)(frame + sample) * source.channels + (size_t)inputChannels + 1u
                ];
                referenceLoudness.process(referenceL, referenceR);
            }
        }
        frame += (uint64_t)framesThisBlock;
    }

    decisions.flush();
    if (!decisions) throw std::runtime_error("failed while writing decision JSONL");
    replay::writeFloat32Wav(config.outputPath, program);

    metrics.decisionTicks = tick;
    metrics.outputSamplePeakDbfs = amplitudeToDb(outputPeak);
    metrics.outputIntegratedLufs = outputLoudness.integrated();
    metrics.outputShortTermLufs = outputLoudness.shortTerm();
    metrics.finalAutoLoudnessTrimDb = brain.currentAutoLoudnessTrimDb();
    const double outputRms = std::sqrt(outputSquares / std::max<uint64_t>(1, outputSamples));
    metrics.outputActive = outputRms > 0.0001;
    if (hasReference) {
        metrics.referenceIntegratedLufs = referenceLoudness.integrated();
        metrics.referenceDeltaLufs =
            metrics.outputIntegratedLufs - metrics.referenceIntegratedLufs;
    }
    metrics.safetyPassed =
        metrics.outputFinite &&
        metrics.outputSamplePeakDbfs <= -0.90f &&
        (!metrics.inputActive || metrics.outputActive);
    writeMetrics(config.metricsPath, config, metrics);
    return metrics;
}

Config parseArgs(int argc, char** argv) {
    Config config;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&]() -> std::string {
            if (++i >= argc) throw std::runtime_error("missing value after " + arg);
            return argv[i];
        };
        if (arg == "--input") config.inputPath = next();
        else if (arg == "--output") config.outputPath = next();
        else if (arg == "--metrics") config.metricsPath = next();
        else if (arg == "--decisions") config.decisionsPath = next();
        else if (arg == "--scene") config.scene = parseScene(next());
        else if (arg == "--block-size") config.blockSize = std::stoi(next());
        else if (arg == "--roles") {
            for (const auto& role : split(next(), ',')) config.roles.push_back(parseRole(role));
        } else if (arg == "--stereo-pairs") {
            config.stereoPairs = parseStereoPairs(next());
        } else {
            throw std::runtime_error("unknown argument: " + arg);
        }
    }
    if (config.inputPath.empty() || config.outputPath.empty() ||
        config.metricsPath.empty() || config.decisionsPath.empty() ||
        config.roles.empty()) {
        throw std::runtime_error(
            "required: --input in.wav --roles r1,r2 --output out.wav "
            "--metrics metrics.json --decisions decisions.jsonl"
        );
    }
    if (config.inputPath == config.outputPath) {
        throw std::runtime_error("input and output WAV paths must differ");
    }
    return config;
}

int selfTest() {
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    const std::string base = "/tmp/live-daw-replay-self-test-" + std::to_string(stamp);
    Config config;
    config.inputPath = base + "-input.wav";
    config.outputPath = base + "-output.wav";
    config.metricsPath = base + "-metrics.json";
    config.decisionsPath = base + "-decisions.jsonl";
    config.roles = {app::Cls::Playback, app::Cls::Playback};
    config.stereoPairs = {{0, 1}};
    config.scene = app::Scene::Worship;
    config.blockSize = 256;

    replay::WavData fixture;
    fixture.sampleRate = 48000;
    fixture.channels = 4; // two raw inputs + stereo approved/reference mix
    const uint64_t frames = (uint64_t)(fixture.sampleRate * 4.2);
    fixture.interleaved.resize((size_t)frames * fixture.channels, 0.0f);
    for (uint64_t frame = 0; frame < frames; ++frame) {
        const double t = (double)frame / fixture.sampleRate;
        const float left = 0.035f * (float)std::sin(2.0 * M_PI * 220.0 * t);
        const float right = 0.012f * (float)std::sin(2.0 * M_PI * 330.0 * t);
        fixture.interleaved[(size_t)frame * 4u] = left;
        fixture.interleaved[(size_t)frame * 4u + 1u] = right;
        fixture.interleaved[(size_t)frame * 4u + 2u] = left * 0.65f;
        fixture.interleaved[(size_t)frame * 4u + 3u] = right * 0.65f;
    }
    replay::writeFloat32Wav(config.inputPath, fixture);

    bool passed = false;
    try {
        const Metrics metrics = evaluate(config);
        const replay::WavData output = replay::readWav(config.outputPath);
        std::ifstream decisions(config.decisionsPath);
        std::string line;
        uint64_t lines = 0;
        while (std::getline(decisions, line)) {
            if (!line.empty()) ++lines;
        }
        passed =
            metrics.safetyPassed &&
            metrics.referenceAvailable &&
            output.channels == 2 &&
            output.frames() == frames &&
            lines >= 80;
    } catch (...) {
        std::remove(config.inputPath.c_str());
        std::remove(config.outputPath.c_str());
        std::remove(config.metricsPath.c_str());
        std::remove(config.decisionsPath.c_str());
        throw;
    }

    std::remove(config.inputPath.c_str());
    std::remove(config.outputPath.c_str());
    std::remove(config.metricsPath.c_str());
    std::remove(config.decisionsPath.c_str());
    if (!passed) throw std::runtime_error("replay self-test output did not meet invariants");
    std::cout << "replay self-test passed\n";
    return 0;
}

void printUsage() {
    std::cerr
        << "Usage:\n"
        << "  automix_replay --input service.wav --roles speech,bass,... \\\n"
        << "    --scene sermon --output program.wav --metrics metrics.json \\\n"
        << "    --decisions decisions.jsonl [--stereo-pairs 11-12,18-19] \\\n"
        << "    [--block-size 256]\n"
        << "  automix_replay --self-test\n";
}

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--self-test") return selfTest();
        const Config config = parseArgs(argc, argv);
        const Metrics metrics = evaluate(config);
        std::cout << std::fixed << std::setprecision(2)
                  << "Rendered " << (double)metrics.frames / metrics.sampleRate << " s, "
                  << metrics.outputIntegratedLufs << " LUFS-I, "
                  << metrics.outputSamplePeakDbfs << " dBFS sample peak, safety "
                  << (metrics.safetyPassed ? "PASS" : "FAIL") << '\n';
        return metrics.safetyPassed ? 0 : 1;
    } catch (const std::exception& error) {
        std::cerr << "automix_replay: " << error.what() << '\n';
        printUsage();
        return 2;
    }
}
