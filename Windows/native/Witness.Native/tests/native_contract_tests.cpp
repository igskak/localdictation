#include "witness_native.h"

#include <array>
#include <cassert>
#include <cstring>

int main() {
    assert(witness_native_abi_version() == 1);

    std::array<char, 128> error{};
    witness_context * context = reinterpret_cast<witness_context *>(0x1);
    const auto invalid = witness_context_create(nullptr, 0, &context, error.data(), error.size());
    assert(invalid == WITNESS_STATUS_INVALID_ARGUMENT);
    assert(context == nullptr);
    assert(std::strlen(error.data()) > 0);

    witness_transcript * transcript = reinterpret_cast<witness_transcript *>(0x1);
    const std::array<float, 1> pcm{0.0F};
    const auto invalid_transcription = witness_transcribe(
        nullptr,
        pcm.data(),
        pcm.size(),
        nullptr,
        1,
        &transcript,
        error.data(),
        error.size());
    assert(invalid_transcription == WITNESS_STATUS_INVALID_ARGUMENT);
    assert(transcript == nullptr);
    assert(witness_transcript_segment_count(nullptr) == 0);
    assert(witness_transcript_language_id(nullptr) == -1);
    assert(witness_transcript_segment_text(nullptr, 0) == nullptr);
    assert(witness_transcript_segment_start_ms(nullptr, 0) == -1);
    assert(witness_transcript_segment_end_ms(nullptr, 0) == -1);
    return 0;
}
