#include "witness_native.h"
#include "wav_fixture.h"

#include <cctype>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {
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
        const auto fixture = witness::tests::read_pcm16_mono(argv[2]);
        if (fixture.sample_rate != 16000) {
            throw std::runtime_error("Fixture must use a 16 kHz sample rate.");
        }
        const std::vector<float> & samples = fixture.samples;
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
