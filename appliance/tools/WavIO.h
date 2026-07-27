#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace replay {

struct WavData {
    uint32_t sampleRate = 0;
    uint16_t channels = 0;
    std::vector<float> interleaved;

    uint64_t frames() const {
        return channels > 0 ? interleaved.size() / channels : 0;
    }
};

inline uint16_t readU16(const uint8_t* p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

inline uint32_t readU32(const uint8_t* p) {
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

inline void writeU16(std::ostream& out, uint16_t value) {
    const uint8_t bytes[2] = {
        (uint8_t)(value & 0xffu),
        (uint8_t)((value >> 8) & 0xffu)
    };
    out.write((const char*)bytes, 2);
}

inline void writeU32(std::ostream& out, uint32_t value) {
    const uint8_t bytes[4] = {
        (uint8_t)(value & 0xffu),
        (uint8_t)((value >> 8) & 0xffu),
        (uint8_t)((value >> 16) & 0xffu),
        (uint8_t)((value >> 24) & 0xffu)
    };
    out.write((const char*)bytes, 4);
}

inline WavData readWav(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("could not open input WAV: " + path);

    uint8_t header[12]{};
    in.read((char*)header, sizeof(header));
    if (in.gcount() != (std::streamsize)sizeof(header) ||
        std::memcmp(header, "RIFF", 4) != 0 ||
        std::memcmp(header + 8, "WAVE", 4) != 0) {
        throw std::runtime_error("input is not a RIFF/WAVE file");
    }

    uint16_t format = 0;
    uint16_t channels = 0;
    uint16_t bitsPerSample = 0;
    uint16_t blockAlign = 0;
    uint32_t sampleRate = 0;
    std::vector<uint8_t> payload;

    while (in && (!format || payload.empty())) {
        uint8_t chunkHeader[8]{};
        in.read((char*)chunkHeader, sizeof(chunkHeader));
        if (in.gcount() != (std::streamsize)sizeof(chunkHeader)) break;
        const uint32_t chunkSize = readU32(chunkHeader + 4);
        if (chunkSize > (1u << 30)) throw std::runtime_error("WAV chunk is unreasonably large");

        if (std::memcmp(chunkHeader, "fmt ", 4) == 0) {
            std::vector<uint8_t> fmt(chunkSize);
            in.read((char*)fmt.data(), chunkSize);
            if (!in || fmt.size() < 16) throw std::runtime_error("invalid WAV fmt chunk");
            format = readU16(fmt.data());
            channels = readU16(fmt.data() + 2);
            sampleRate = readU32(fmt.data() + 4);
            blockAlign = readU16(fmt.data() + 12);
            bitsPerSample = readU16(fmt.data() + 14);
            if (format == 0xfffe && fmt.size() >= 40) {
                format = readU16(fmt.data() + 24); // extensible sub-format GUID prefix
            }
        } else if (std::memcmp(chunkHeader, "data", 4) == 0) {
            payload.resize(chunkSize);
            in.read((char*)payload.data(), chunkSize);
            if (!in) throw std::runtime_error("truncated WAV data chunk");
        } else {
            in.seekg(chunkSize, std::ios::cur);
        }
        if (chunkSize & 1u) in.seekg(1, std::ios::cur);
    }

    if (!format || payload.empty()) throw std::runtime_error("WAV is missing fmt or data");
    if (channels == 0 || channels > 128 || sampleRate < 8000 || sampleRate > 384000) {
        throw std::runtime_error("unsupported WAV channel count or sample rate");
    }
    if (blockAlign == 0 || payload.size() % blockAlign != 0) {
        throw std::runtime_error("WAV data is not aligned to complete frames");
    }

    const int bytesPerSample = (bitsPerSample + 7) / 8;
    if (blockAlign < channels * bytesPerSample) {
        throw std::runtime_error("invalid WAV block alignment");
    }
    const uint64_t frameCount = payload.size() / blockAlign;
    if (frameCount > std::numeric_limits<size_t>::max() / channels) {
        throw std::runtime_error("WAV is too large for this process");
    }

    WavData result;
    result.sampleRate = sampleRate;
    result.channels = channels;
    result.interleaved.resize((size_t)frameCount * channels);
    for (uint64_t frame = 0; frame < frameCount; ++frame) {
        const uint8_t* frameData = payload.data() + (size_t)frame * blockAlign;
        for (uint16_t channel = 0; channel < channels; ++channel) {
            const uint8_t* sample = frameData + (size_t)channel * bytesPerSample;
            float value = 0.0f;
            if (format == 3 && bitsPerSample == 32) {
                const uint32_t raw = readU32(sample);
                std::memcpy(&value, &raw, sizeof(value));
            } else if (format == 1 && bitsPerSample == 16) {
                const int16_t raw = (int16_t)readU16(sample);
                value = (float)raw / 32768.0f;
            } else if (format == 1 && bitsPerSample == 24) {
                int32_t raw = (int32_t)sample[0] |
                              ((int32_t)sample[1] << 8) |
                              ((int32_t)sample[2] << 16);
                if (raw & 0x00800000) raw |= (int32_t)0xff000000;
                value = (float)raw / 8388608.0f;
            } else if (format == 1 && bitsPerSample == 32) {
                const int32_t raw = (int32_t)readU32(sample);
                value = (float)((double)raw / 2147483648.0);
            } else {
                throw std::runtime_error("WAV must be PCM16/24/32 or IEEE float32");
            }
            result.interleaved[(size_t)frame * channels + channel] = value;
        }
    }
    return result;
}

inline void writeFloat32Wav(const std::string& path, const WavData& wav) {
    if (wav.channels == 0 || wav.sampleRate == 0 ||
        wav.interleaved.size() % wav.channels != 0) {
        throw std::runtime_error("invalid WAV output shape");
    }
    const uint64_t dataBytes64 = wav.interleaved.size() * sizeof(float);
    if (dataBytes64 > std::numeric_limits<uint32_t>::max() - 44u) {
        throw std::runtime_error("WAV output exceeds RIFF's 4 GiB limit");
    }

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("could not create output WAV: " + path);
    const uint32_t dataBytes = (uint32_t)dataBytes64;
    out.write("RIFF", 4);
    writeU32(out, 36u + dataBytes);
    out.write("WAVE", 4);
    out.write("fmt ", 4);
    writeU32(out, 16);
    writeU16(out, 3); // IEEE float
    writeU16(out, wav.channels);
    writeU32(out, wav.sampleRate);
    const uint16_t blockAlign = (uint16_t)(wav.channels * sizeof(float));
    writeU32(out, wav.sampleRate * blockAlign);
    writeU16(out, blockAlign);
    writeU16(out, 32);
    out.write("data", 4);
    writeU32(out, dataBytes);
    out.write((const char*)wav.interleaved.data(), dataBytes);
    if (!out) throw std::runtime_error("failed while writing output WAV");
}

inline uint32_t crc32File(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("could not hash input file: " + path);
    uint32_t crc = 0xffffffffu;
    char buffer[16384];
    while (in) {
        in.read(buffer, sizeof(buffer));
        const std::streamsize count = in.gcount();
        for (std::streamsize i = 0; i < count; ++i) {
            crc ^= (uint8_t)buffer[i];
            for (int bit = 0; bit < 8; ++bit) {
                crc = (crc >> 1) ^ (0xedb88320u & (uint32_t)-(int32_t)(crc & 1u));
            }
        }
    }
    return ~crc;
}

} // namespace replay
