#include "witness_native.h"

#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

namespace {

bool close(float left, float right) {
    return std::fabs(left - right) < 0.0001F;
}

template <size_t Size>
void expect_decode(
    const std::array<uint8_t, Size> & input,
    size_t frames,
    uint32_t channels,
    witness_audio_sample_format format,
    const float * expected) {
    std::array<float, 8> output{};
    size_t written = 99;
    const auto status = witness_audio_decode_to_mono(
        input.data(), input.size(), frames, channels, format,
        output.data(), output.size(), &written);
    assert(status == WITNESS_STATUS_OK);
    assert(written == frames);
    for (size_t index = 0; index < frames; ++index) assert(close(output[index], expected[index]));
}

}  // namespace

int main() {
    const std::array<uint8_t, 8> pcm16{
        0x00, 0x40, 0x00, 0xC0,  // stereo average 0
        0xFF, 0x7F, 0xFF, 0x7F,  // stereo near +1
    };
    const std::array<float, 2> pcm16_expected{0.0F, 32767.0F / 32768.0F};
    expect_decode(pcm16, 2, 2, WITNESS_AUDIO_PCM16_LE, pcm16_expected.data());

    const std::array<uint8_t, 6> pcm24{
        0x00, 0x00, 0x40,  // +0.5
        0x00, 0x00, 0xC0,  // -0.5
    };
    const std::array<float, 2> pcm24_expected{0.5F, -0.5F};
    expect_decode(pcm24, 2, 1, WITNESS_AUDIO_PCM24_LE, pcm24_expected.data());

    const std::array<uint8_t, 8> pcm32{
        0x00, 0x00, 0x00, 0x40,  // +0.5
        0x00, 0x00, 0x00, 0xC0,  // -0.5
    };
    const std::array<float, 2> pcm32_expected{0.5F, -0.5F};
    expect_decode(pcm32, 2, 1, WITNESS_AUDIO_PCM32_LE, pcm32_expected.data());

    std::array<float, 4> float_values{1.25F, -1.25F, std::numeric_limits<float>::quiet_NaN(), 0.25F};
    std::array<uint8_t, sizeof(float_values)> float_bytes{};
    std::memcpy(float_bytes.data(), float_values.data(), float_bytes.size());
    const std::array<float, 2> float_expected{0.0F, 0.125F};
    expect_decode(float_bytes, 2, 2, WITNESS_AUDIO_FLOAT32_LE, float_expected.data());

    std::array<float, 2> output{};
    size_t written = 7;
    assert(witness_audio_decode_to_mono(
        pcm16.data(), pcm16.size() - 1, 2, 2, WITNESS_AUDIO_PCM16_LE,
        output.data(), output.size(), &written) == WITNESS_STATUS_INVALID_ARGUMENT);
    assert(written == 0);
    assert(witness_audio_decode_to_mono(
        pcm16.data(), pcm16.size(), 2, 0, WITNESS_AUDIO_PCM16_LE,
        output.data(), output.size(), &written) == WITNESS_STATUS_INVALID_ARGUMENT);
    return 0;
}
