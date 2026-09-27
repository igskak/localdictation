#include "witness_native.h"

#include <array>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cmath>
#include <vector>

namespace {

void verify_rate(uint32_t input_rate) {
    std::vector<float> input(input_rate);
    for (size_t index = 0; index < input.size(); ++index) {
        input[index] = 0.25F * std::sin(2.0 * 3.141592653589793 * 440.0 * index / input_rate);
    }
    std::array<char, 256> error{};
    witness_audio_buffer * output = nullptr;
    const auto status = witness_audio_resample_to_16khz(
        input.data(), input.size(), input_rate, &output, error.data(), error.size());
    assert(status == WITNESS_STATUS_OK);
    assert(output != nullptr);
    const size_t count = witness_audio_buffer_sample_count(output);
    assert(count >= 15900 && count <= 16100);
    const float * samples = witness_audio_buffer_data(output);
    assert(samples != nullptr);
    for (size_t index = 0; index < count; ++index) assert(std::isfinite(samples[index]));
    witness_audio_buffer_destroy(output);
}

}  // namespace

int main() {
    verify_rate(44100);
    verify_rate(48000);

    std::array<char, 128> error{};
    witness_audio_buffer * output = reinterpret_cast<witness_audio_buffer *>(0x1);
    assert(witness_audio_resample_to_16khz(
        nullptr, 0, 48000, &output, error.data(), error.size()) == WITNESS_STATUS_INVALID_ARGUMENT);
    assert(output == nullptr);
    assert(witness_audio_buffer_data(nullptr) == nullptr);
    assert(witness_audio_buffer_sample_count(nullptr) == 0);
    witness_audio_buffer_destroy(nullptr);
    return 0;
}
