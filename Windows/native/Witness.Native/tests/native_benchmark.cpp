#include "witness_native.h"
#include "wav_fixture.h"

#include <array>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

constexpr uint32_t kEngineSampleRate = 16000;
constexpr int kMaximumIterations = 20;

struct Timings {
    double load_ms = 0;
    double detection_ms = 0;
    double transcription_ms = 0;
};

double elapsed_ms(Clock::time_point started) {
    return std::chrono::duration<double, std::milli>(Clock::now() - started).count();
}

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
        throw std::runtime_error(std::string{"Could not resample synthetic benchmark fixture: "} + error.data());
    }

    const float * data = witness_audio_buffer_data(output.get());
    const size_t count = witness_audio_buffer_sample_count(output.get());
    if (data == nullptr || count == 0) {
        throw std::runtime_error("Resampling produced an empty synthetic benchmark fixture.");
    }
    return std::vector<float>(data, data + count);
}

int parse_iterations(const char * value) {
    const std::string text{value};
    size_t consumed = 0;
    const int result = std::stoi(text, &consumed);
    if (consumed != text.size() || result < 1 || result > kMaximumIterations) {
        throw std::invalid_argument("Iterations must be an integer from 1 through 20.");
    }
    return result;
}

bool parse_gpu(const char * value) {
    const std::string_view backend{value};
    if (backend == "cpu") {
        return false;
    }
    if (backend == "gpu") {
        return true;
    }
    throw std::invalid_argument("Backend must be cpu or gpu.");
}

void require_status(witness_status status, const std::array<char, 512> & error, const char * stage) {
    if (status != WITNESS_STATUS_OK) {
        throw std::runtime_error(std::string{stage} + " failed: " + error.data());
    }
}

}  // namespace

int main(int argc, char ** argv) {
    if (argc != 6) {
        std::cerr << "Usage: witness_native_benchmark <model> <synthetic-wav> <language> <cpu|gpu> <iterations>\n";
        return 2;
    }

    try {
        const bool use_gpu = parse_gpu(argv[4]);
        const int iterations = parse_iterations(argv[5]);
        const auto samples = to_16khz(witness::tests::read_pcm16_mono(argv[2]));
        std::array<char, 512> error{};
        Timings timings;

        const auto load_started = Clock::now();
        witness_context * native_context = nullptr;
        require_status(
            witness_context_create(argv[1], use_gpu ? 1 : 0, &native_context, error.data(), error.size()),
            error,
            "Model load");
        std::unique_ptr<witness_context, decltype(&witness_context_destroy)> context(
            native_context,
            witness_context_destroy);
        timings.load_ms = elapsed_ms(load_started);

        if (context == nullptr || witness_context_uses_gpu(context.get()) != (use_gpu ? 1 : 0)) {
            throw std::runtime_error("The native context did not activate the requested backend.");
        }

        for (int iteration = 0; iteration < iterations; ++iteration) {
            witness_language_scores * native_scores = nullptr;
            const auto detection_started = Clock::now();
            require_status(
                witness_detect_languages(
                    context.get(),
                    samples.data(),
                    samples.size(),
                    2,
                    nullptr,
                    &native_scores,
                    error.data(),
                    error.size()),
                error,
                "Language detection");
            timings.detection_ms += elapsed_ms(detection_started);
            std::unique_ptr<witness_language_scores, decltype(&witness_language_scores_destroy)> scores(
                native_scores,
                witness_language_scores_destroy);
            if (scores == nullptr || witness_language_scores_count(scores.get()) == 0) {
                throw std::runtime_error("Language detection returned no scores.");
            }

            witness_transcript * native_transcript = nullptr;
            const auto transcription_started = Clock::now();
            require_status(
                witness_transcribe(
                    context.get(),
                    samples.data(),
                    samples.size(),
                    argv[3],
                    2,
                    &native_transcript,
                    error.data(),
                    error.size()),
                error,
                "Explicit transcription");
            timings.transcription_ms += elapsed_ms(transcription_started);
            std::unique_ptr<witness_transcript, decltype(&witness_transcript_destroy)> transcript(
                native_transcript,
                witness_transcript_destroy);
            if (transcript == nullptr || witness_transcript_segment_count(transcript.get()) == 0) {
                throw std::runtime_error("Explicit transcription returned no segments.");
            }
        }

        const double audio_ms = static_cast<double>(samples.size()) * 1000.0 / kEngineSampleRate;
        std::cout << "backend=" << (use_gpu ? "gpu" : "cpu")
                  << " iterations=" << iterations
                  << " samples=" << samples.size()
                  << " audio_ms=" << audio_ms
                  << " load_ms=" << timings.load_ms
                  << " detection_mean_ms=" << timings.detection_ms / iterations
                  << " transcription_mean_ms=" << timings.transcription_ms / iterations
                  << '\n';
        return 0;
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return 3;
    }
}
