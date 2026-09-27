#include "witness_native.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace {

size_t bytes_per_sample(witness_audio_sample_format format) noexcept {
    switch (format) {
        case WITNESS_AUDIO_PCM16_LE:
            return 2;
        case WITNESS_AUDIO_PCM24_LE:
            return 3;
        case WITNESS_AUDIO_PCM32_LE:
        case WITNESS_AUDIO_FLOAT32_LE:
            return 4;
        default:
            return 0;
    }
}

float decode_sample(const uint8_t * source, witness_audio_sample_format format) noexcept {
    switch (format) {
        case WITNESS_AUDIO_PCM16_LE: {
            const auto value = static_cast<int16_t>(
                static_cast<uint16_t>(source[0]) |
                static_cast<uint16_t>(static_cast<uint16_t>(source[1]) << 8U));
            return static_cast<float>(value) / 32768.0F;
        }
        case WITNESS_AUDIO_PCM24_LE: {
            int32_t value = static_cast<int32_t>(source[0]) |
                (static_cast<int32_t>(source[1]) << 8U) |
                (static_cast<int32_t>(source[2]) << 16U);
            if ((value & 0x00800000) != 0) value -= 1 << 24;
            return static_cast<float>(value) / 8388608.0F;
        }
        case WITNESS_AUDIO_PCM32_LE: {
            const auto bits = static_cast<uint32_t>(source[0]) |
                (static_cast<uint32_t>(source[1]) << 8U) |
                (static_cast<uint32_t>(source[2]) << 16U) |
                (static_cast<uint32_t>(source[3]) << 24U);
            int32_t value = 0;
            std::memcpy(&value, &bits, sizeof(value));
            return static_cast<float>(static_cast<double>(value) / 2147483648.0);
        }
        case WITNESS_AUDIO_FLOAT32_LE: {
            const auto bits = static_cast<uint32_t>(source[0]) |
                (static_cast<uint32_t>(source[1]) << 8U) |
                (static_cast<uint32_t>(source[2]) << 16U) |
                (static_cast<uint32_t>(source[3]) << 24U);
            float value = 0.0F;
            std::memcpy(&value, &bits, sizeof(value));
            return std::isfinite(value) ? std::clamp(value, -1.0F, 1.0F) : 0.0F;
        }
        default:
            return 0.0F;
    }
}

}  // namespace

extern "C" enum witness_status witness_audio_decode_to_mono(
    const void * input,
    size_t input_size_bytes,
    size_t frame_count,
    uint32_t channel_count,
    enum witness_audio_sample_format format,
    float * output,
    size_t output_capacity_frames,
    size_t * output_frame_count) {
    if (output_frame_count != nullptr) *output_frame_count = 0;
    const size_t sample_width = bytes_per_sample(format);
    if (output_frame_count == nullptr || channel_count == 0 || channel_count > 32 || sample_width == 0 ||
        frame_count > output_capacity_frames || (frame_count > 0 && (input == nullptr || output == nullptr))) {
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    if (frame_count > std::numeric_limits<size_t>::max() / channel_count ||
        frame_count * channel_count > std::numeric_limits<size_t>::max() / sample_width ||
        frame_count * channel_count * sample_width > input_size_bytes) {
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }

    const auto * bytes = static_cast<const uint8_t *>(input);
    for (size_t frame = 0; frame < frame_count; ++frame) {
        double sum = 0.0;
        for (uint32_t channel = 0; channel < channel_count; ++channel) {
            const size_t sample_index = frame * channel_count + channel;
            sum += decode_sample(bytes + sample_index * sample_width, format);
        }
        output[frame] = std::clamp(static_cast<float>(sum / channel_count), -1.0F, 1.0F);
    }
    *output_frame_count = frame_count;
    return WITNESS_STATUS_OK;
}
