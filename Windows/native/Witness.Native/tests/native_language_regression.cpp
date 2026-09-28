#include "witness_native.h"
#include "wav_fixture.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kEngineSampleRate = 16000;
constexpr std::array<int, 4> kLeadingNoiseMilliseconds{500, 1000, 1500, 2500};

struct LanguageCase {
    const char * expected;
    const char * path;
    std::vector<const char *> profile;
};

std::vector<float> to_16khz(witness::tests::WavFixture fixture) {
    if (fixture.sample_rate == kEngineSampleRate) {
        return std::move(fixture.samples);
    }
    witness_audio_buffer * native_output = nullptr;
    std::array<char, 512> error{};
    const auto status = witness_audio_resample_to_16khz(
        fixture.samples.data(),
        fixture.samples.size(),
        fixture.sample_rate,
        &native_output,
        error.data(),
        error.size());
    std::unique_ptr<witness_audio_buffer, decltype(&witness_audio_buffer_destroy)> output(
        native_output,
        witness_audio_buffer_destroy);
    if (status != WITNESS_STATUS_OK || output == nullptr) {
        throw std::runtime_error(std::string{"Could not resample synthetic fixture: "} + error.data());
    }
    const float * data = witness_audio_buffer_data(output.get());
    const size_t count = witness_audio_buffer_sample_count(output.get());
    if (data == nullptr || count == 0) {
        throw std::runtime_error("Resampling produced an empty synthetic fixture.");
    }
    std::vector<float> samples(data, data + count);
    return samples;
}

std::vector<float> with_leading_noise(const std::vector<float> & speech, int milliseconds) {
    const size_t noise_count = static_cast<size_t>(milliseconds) * kEngineSampleRate / 1000U;
    std::vector<float> result(noise_count + speech.size());
    uint32_t state = 0x9e3779b9U ^ static_cast<uint32_t>(milliseconds);
    for (size_t index = 0; index < noise_count; ++index) {
        state ^= state << 13U;
        state ^= state >> 17U;
        state ^= state << 5U;
        const float unit = static_cast<float>(state & 0xffffU) / 32767.5F - 1.0F;
        result[index] = unit * 0.001F;
    }
    std::copy(speech.begin(), speech.end(), result.begin() + static_cast<std::ptrdiff_t>(noise_count));
    return result;
}

float score_for(const witness_language_scores * scores, const char * expected_code) {
    const size_t count = witness_language_scores_count(scores);
    for (size_t index = 0; index < count; ++index) {
        const char * code = witness_language_score_code(scores, index);
        if (code != nullptr && std::string{code} == expected_code) {
            return witness_language_score_probability(scores, index);
        }
    }
    return -1.0F;
}

std::string choose_profile_language(
    const witness_language_scores * scores,
    const std::vector<const char *> & profile) {
    std::string selected;
    float selected_probability = -std::numeric_limits<float>::infinity();
    for (const char * code : profile) {
        const float probability = score_for(scores, code);
        if (probability > selected_probability) {
            selected = code;
            selected_probability = probability;
        }
    }
    return selected;
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

void require_explicit_transcript(
    witness_context * context,
    const std::vector<float> & samples,
    const char * language) {
    std::array<char, 512> error{};
    witness_transcript * transcript = nullptr;
    const auto status = witness_transcribe(
        context,
        samples.data(),
        samples.size(),
        language,
        2,
        &transcript,
        error.data(),
        error.size());
    if (status != WITNESS_STATUS_OK || transcript == nullptr) {
        witness_transcript_destroy(transcript);
        throw std::runtime_error(std::string{"Explicit transcription failed for "} + language + ": " + error.data());
    }
    bool has_text = false;
    for (size_t index = 0; index < witness_transcript_segment_count(transcript); ++index) {
        has_text = has_text || contains_non_whitespace(witness_transcript_segment_text(transcript, index));
    }
    witness_transcript_destroy(transcript);
    if (!has_text) {
        throw std::runtime_error(std::string{"Explicit transcription was empty for "} + language + ".");
    }
}

}  // namespace

int main(int argc, char ** argv) {
    if (argc != 6) {
        std::cerr << "Usage: witness_native_language_regression <model> <de.wav> <en.wav> <ru.wav> <uk.wav>\n";
        return 2;
    }
    try {
        std::array<char, 512> error{};
        witness_context * native_context = nullptr;
        if (witness_context_create(argv[1], 0, &native_context, error.data(), error.size()) != WITNESS_STATUS_OK) {
            std::cerr << "CPU product-model load failed: " << error.data() << '\n';
            return 3;
        }
        std::unique_ptr<witness_context, decltype(&witness_context_destroy)> context(
            native_context,
            witness_context_destroy);

        const std::array<LanguageCase, 4> cases{{
            {"de", argv[2], {"de", "en"}},
            {"en", argv[3], {"ru", "en", "uk"}},
            {"ru", argv[4], {"ru", "en", "uk"}},
            {"uk", argv[5], {"ru", "en", "uk"}},
        }};

        for (const auto & language_case : cases) {
            const auto base = to_16khz(witness::tests::read_pcm16_mono(language_case.path));
            require_explicit_transcript(context.get(), base, language_case.expected);
            for (const int delay : kLeadingNoiseMilliseconds) {
                const auto samples = with_leading_noise(base, delay);
                witness_language_scores * scores = nullptr;
                const auto status = witness_detect_languages(
                    context.get(),
                    samples.data(),
                    samples.size(),
                    2,
                    nullptr,
                    &scores,
                    error.data(),
                    error.size());
                if (status != WITNESS_STATUS_OK || scores == nullptr) {
                    witness_language_scores_destroy(scores);
                    std::cerr << "Language detection failed for " << language_case.expected
                              << " with " << delay << " ms leading noise: " << error.data() << '\n';
                    return 4;
                }
                const std::string selected = choose_profile_language(scores, language_case.profile);
                std::cout << language_case.expected << " +" << delay << "ms: selected=" << selected
                          << " expected_score=" << score_for(scores, language_case.expected) << '\n';
                witness_language_scores_destroy(scores);
                if (selected != language_case.expected) {
                    std::cerr << "Wrong selected language for the configured mixed profile.\n";
                    return 5;
                }
            }
        }

        std::cout << "All 16 leading-noise language decisions and four explicit transcriptions passed.\n";
        return 0;
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return 6;
    }
}
