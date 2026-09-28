#include "witness_native.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

uint16_t read_u16(std::istream & input) {
    std::array<unsigned char, 2> bytes{};
    input.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    if (!input) {
        throw std::runtime_error("Unexpected end of WAV file.");
    }
    return static_cast<uint16_t>(bytes[0]) | (static_cast<uint16_t>(bytes[1]) << 8U);
}

uint32_t read_u32(std::istream & input) {
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

std::string read_tag(std::istream & input) {
    std::array<char, 4> value{};
    input.read(value.data(), static_cast<std::streamsize>(value.size()));
    if (!input) {
        throw std::runtime_error("Unexpected end of WAV file.");
    }
    return std::string(value.data(), value.size());
}

std::vector<float> read_pcm16_mono_16khz(const char * path) {
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
    if (format != 1 || channels != 1 || sample_rate != 16000 || bits != 16 || pcm.empty()) {
        throw std::runtime_error("Fixture must be non-empty PCM16 mono at 16 kHz.");
    }
    std::vector<float> samples;
    samples.reserve(pcm.size());
    std::transform(pcm.begin(), pcm.end(), std::back_inserter(samples), [](int16_t value) {
        return static_cast<float>(value) / 32768.0F;
    });
    return samples;
}

bool contains_non_whitespace(const char * text) {
    if (text == nullptr) {
        return false;
    }
    for (const unsigned char * cursor = reinterpret_cast<const unsigned char *>(text); *cursor != 0; ++cursor) {
        if (std::isspace(*cursor) == 0) {
            return true;
        }
    }
    return false;
}

}  // namespace

int main(int argc, char ** argv) {
    if (argc != 3) {
        std::cerr << "Usage: witness_native_inference_smoke <model> <synthetic-wav>\n";
        return 2;
    }
    try {
        const std::vector<float> samples = read_pcm16_mono_16khz(argv[2]);
        std::array<char, 512> error{};
        witness_context * context = nullptr;
        if (witness_context_create(argv[1], 0, &context, error.data(), error.size()) != WITNESS_STATUS_OK) {
            std::cerr << "CPU model load failed: " << error.data() << '\n';
            return 3;
        }

        witness_transcript * transcript = nullptr;
        const witness_status status = witness_transcribe(
            context,
            samples.data(),
            samples.size(),
            "en",
            2,
            &transcript,
            error.data(),
            error.size());
        witness_context_destroy(context);
        if (status != WITNESS_STATUS_OK || transcript == nullptr) {
            std::cerr << "CPU transcription failed: " << error.data() << '\n';
            witness_transcript_destroy(transcript);
            return 4;
        }

        const size_t count = witness_transcript_segment_count(transcript);
        const char * language = witness_transcript_language(transcript);
        const std::string language_code = language == nullptr ? std::string{} : std::string{language};
        bool has_text = false;
        bool has_valid_timing = false;
        bool has_token = false;
        bool has_only_segment_timing = true;
        for (size_t index = 0; index < count; ++index) {
            has_text = has_text || contains_non_whitespace(witness_transcript_segment_text(transcript, index));
            const int64_t start = witness_transcript_segment_start_ms(transcript, index);
            const int64_t end = witness_transcript_segment_end_ms(transcript, index);
            has_valid_timing = has_valid_timing || (start >= 0 && end > start);
            const size_t token_count = witness_transcript_segment_token_count(transcript, index);
            for (size_t token_index = 0; token_index < token_count; ++token_index) {
                has_token = has_token || contains_non_whitespace(
                    witness_transcript_token_text(transcript, index, token_index));
                has_only_segment_timing = has_only_segment_timing
                    && witness_transcript_token_start_ms(transcript, index, token_index) == -1
                    && witness_transcript_token_end_ms(transcript, index, token_index) == -1;
            }
        }
        witness_transcript_destroy(transcript);
        if (count == 0 || !has_text || !has_valid_timing || !has_token || !has_only_segment_timing
            || language_code != "en") {
            std::cerr << "Inference produced no non-empty timed English transcript with tokens.\n";
            return 5;
        }

        std::cout << "RAM-only CPU inference produced a non-empty timed segment.\n";
        return 0;
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return 6;
    }
}
