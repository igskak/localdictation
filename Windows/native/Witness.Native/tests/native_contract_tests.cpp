#include "witness_native.h"

#include <array>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstring>

namespace {
void ignore_audio(void *, const void *, size_t, size_t, uint32_t) {}
}

int main() {
    assert(witness_native_abi_version() == 2);

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
    assert(witness_transcript_language(nullptr) == nullptr);
    assert(witness_transcript_segment_token_count(nullptr, 0) == 0);
    assert(witness_transcript_token_text(nullptr, 0, 0) == nullptr);
    assert(witness_transcript_token_probability(nullptr, 0, 0) == 0.0F);
    assert(witness_transcript_token_start_ms(nullptr, 0, 0) == -1);
    assert(witness_transcript_token_end_ms(nullptr, 0, 0) == -1);

    assert(witness_cancellation_create(nullptr) == WITNESS_STATUS_INVALID_ARGUMENT);
    witness_cancellation * cancellation = nullptr;
    assert(witness_cancellation_create(&cancellation) == WITNESS_STATUS_OK);
    assert(cancellation != nullptr);
    witness_cancellation_cancel(cancellation);
    witness_cancellation_destroy(cancellation);

    witness_audio_capture * capture = reinterpret_cast<witness_audio_capture *>(0x1);
    const auto invalid_capture = witness_audio_capture_create(
        nullptr, nullptr, nullptr, &capture, error.data(), error.size());
    assert(invalid_capture == WITNESS_STATUS_INVALID_ARGUMENT);
    assert(capture == nullptr);
    const auto valid_capture = witness_audio_capture_create(
        nullptr, ignore_audio, nullptr, &capture, error.data(), error.size());
    assert(valid_capture == WITNESS_STATUS_OK);
    assert(capture != nullptr);
    witness_audio_capture_stop(capture);
    witness_audio_capture_destroy(capture);

    witness_audio_device_list * devices = reinterpret_cast<witness_audio_device_list *>(0x1);
    const auto invalid_devices = witness_audio_device_list_create(nullptr, error.data(), error.size());
    assert(invalid_devices == WITNESS_STATUS_INVALID_ARGUMENT);
    const auto device_status = witness_audio_device_list_create(&devices, error.data(), error.size());
    assert(device_status == WITNESS_STATUS_OK || device_status == WITNESS_STATUS_AUDIO_DEVICE_UNAVAILABLE);
    if (device_status == WITNESS_STATUS_OK) {
        const size_t device_count = witness_audio_device_list_count(devices);
        for (size_t index = 0; index < device_count; ++index) {
            assert(witness_audio_device_id(devices, index) != nullptr);
            assert(witness_audio_device_name(devices, index) != nullptr);
        }
    }
    witness_audio_device_list_destroy(devices);
    return 0;
}
