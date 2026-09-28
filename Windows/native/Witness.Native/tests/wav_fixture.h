#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace witness::tests {

struct WavFixture {
    uint32_t sample_rate;
    std::vector<float> samples;
};

inline uint16_t read_u16(std::istream & input) {
    std::array<unsigned char, 2> bytes{};
    input.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    if (!input) {
        throw std::runtime_error("Unexpected end of WAV file.");
    }
    return static_cast<uint16_t>(bytes[0]) | (static_cast<uint16_t>(bytes[1]) << 8U);
}

inline uint32_t read_u32(std::istream & input) {
    std::array<unsigned char, 4> bytes{};
    input.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    if (!input) {
        throw std::runtime_error("Unexpected end of WAV file.");
    }
    return static_cast<uint32_t>(bytes[0])
        | (static_cast<uint32_t>(bytes[1]) << 8U)
        | (static_cast<uint32_t>(bytes[2]) << 16U)
        | (static_cast<uint32_t>(bytes[3]) << 24U);
}

inline std::string read_tag(std::istream & input) {
    std::array<char, 4> value{};
    input.read(value.data(), static_cast<std::streamsize>(value.size()));
    if (!input) {
        throw std::runtime_error("Unexpected end of WAV file.");
    }
    return std::string(value.data(), value.size());
}

inline WavFixture read_pcm16_mono(const char * path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("Could not open the synthetic WAV fixture.");
    }
    if (read_tag(input) != "RIFF") {
        throw std::runtime_error("Synthetic fixture is not RIFF WAV.");
    }
    static_cast<void>(read_u32(input));
    if (read_tag(input) != "WAVE") {
        throw std::runtime_error("Synthetic fixture is not WAVE.");
    }

    uint16_t format = 0;
    uint16_t channels = 0;
    uint32_t sample_rate = 0;
    uint16_t bits = 0;
    std::vector<int16_t> pcm;
    while (input && (format == 0 || pcm.empty())) {
        const std::string tag = read_tag(input);
        const uint32_t size = read_u32(input);
        if (tag == "fmt ") {
            format = read_u16(input);
            channels = read_u16(input);
            sample_rate = read_u32(input);
            static_cast<void>(read_u32(input));
            static_cast<void>(read_u16(input));
            bits = read_u16(input);
            if (size < 16) {
                throw std::runtime_error("Invalid WAV format chunk.");
            }
            input.seekg(static_cast<std::streamoff>(size - 16), std::ios::cur);
        } else if (tag == "data") {
            if ((size % sizeof(int16_t)) != 0) {
                throw std::runtime_error("PCM data has an invalid byte count.");
            }
            pcm.resize(size / sizeof(int16_t));
            input.read(reinterpret_cast<char *>(pcm.data()), static_cast<std::streamsize>(size));
            if (!input) {
                throw std::runtime_error("PCM data is truncated.");
            }
        } else {
            input.seekg(static_cast<std::streamoff>(size), std::ios::cur);
        }
        if ((size & 1U) != 0U) {
            input.seekg(1, std::ios::cur);
        }
    }
    if (format != 1 || channels != 1 || sample_rate == 0 || bits != 16 || pcm.empty()) {
        throw std::runtime_error("Fixture must be non-empty PCM16 mono WAV.");
    }

    std::vector<float> samples;
    samples.reserve(pcm.size());
    std::transform(pcm.begin(), pcm.end(), std::back_inserter(samples), [](int16_t value) {
        return static_cast<float>(value) / 32768.0F;
    });
    return WavFixture{sample_rate, std::move(samples)};
}

}  // namespace witness::tests
