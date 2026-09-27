#include "witness_native.h"

#include <whisper.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr uint32_t kAbiVersion = 1;
constexpr size_t kMinimumSamples = 1;
constexpr size_t kMaximumSamples = 16000ULL * 600ULL;

struct WhisperDeleter {
    void operator()(whisper_context * value) const noexcept {
        if (value != nullptr) {
            whisper_free(value);
        }
    }
};

struct Segment {
    std::string text;
    int64_t start_ms;
    int64_t end_ms;
};

void write_error(char * destination, size_t capacity, const char * message) noexcept {
    if (destination == nullptr || capacity == 0) {
        return;
    }

    const char * safe_message = message == nullptr ? "Unknown native error" : message;
    const size_t length = std::min(capacity - 1, std::strlen(safe_message));
    std::memcpy(destination, safe_message, length);
    destination[length] = '\0';
}

void clear_error(char * destination, size_t capacity) noexcept {
    if (destination != nullptr && capacity > 0) {
        destination[0] = '\0';
    }
}

}  // namespace

struct witness_context {
    std::unique_ptr<whisper_context, WhisperDeleter> whisper;
};

struct witness_transcript {
    int language_id = -1;
    std::vector<Segment> segments;
};

extern "C" uint32_t witness_native_abi_version(void) {
    return kAbiVersion;
}

extern "C" enum witness_status witness_context_create(
    const char * model_path_utf8,
    int use_gpu,
    witness_context ** result,
    char * error_utf8,
    size_t error_capacity) {
    clear_error(error_utf8, error_capacity);
    if (result != nullptr) {
        *result = nullptr;
    }
    if (result == nullptr || model_path_utf8 == nullptr || model_path_utf8[0] == '\0') {
        write_error(error_utf8, error_capacity, "A model path and result pointer are required.");
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    try {
        auto parameters = whisper_context_default_params();
        parameters.use_gpu = use_gpu != 0;
        auto native = std::unique_ptr<whisper_context, WhisperDeleter>(
            whisper_init_from_file_with_params(model_path_utf8, parameters));
        if (!native) {
            write_error(error_utf8, error_capacity, "whisper.cpp could not load the selected model.");
            return WITNESS_STATUS_MODEL_LOAD_FAILED;
        }

        auto owned = std::make_unique<witness_context>();
        owned->whisper = std::move(native);
        *result = owned.release();
        return WITNESS_STATUS_OK;
    } catch (const std::bad_alloc &) {
        write_error(error_utf8, error_capacity, "Not enough memory to load the speech model.");
        return WITNESS_STATUS_OUT_OF_MEMORY;
    } catch (const std::exception & error) {
        write_error(error_utf8, error_capacity, error.what());
        return WITNESS_STATUS_INTERNAL_ERROR;
    } catch (...) {
        write_error(error_utf8, error_capacity, "Unknown native error while loading the speech model.");
        return WITNESS_STATUS_INTERNAL_ERROR;
    }
}

extern "C" void witness_context_destroy(witness_context * context) {
    delete context;
}

extern "C" enum witness_status witness_transcribe(
    witness_context * context,
    const float * pcm_16khz_mono,
    size_t sample_count,
    const char * language_utf8,
    int thread_count,
    witness_transcript ** result,
    char * error_utf8,
    size_t error_capacity) {
    clear_error(error_utf8, error_capacity);
    if (result != nullptr) {
        *result = nullptr;
    }
    if (result == nullptr || context == nullptr || context->whisper == nullptr || pcm_16khz_mono == nullptr
        || sample_count < kMinimumSamples || sample_count > kMaximumSamples || thread_count < 1) {
        write_error(error_utf8, error_capacity, "The transcription request is invalid.");
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    try {
        auto parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        parameters.n_threads = thread_count;
        parameters.translate = false;
        parameters.no_context = true;
        parameters.no_timestamps = false;
        parameters.single_segment = false;
        parameters.print_special = false;
        parameters.print_progress = false;
        parameters.print_realtime = false;
        parameters.print_timestamps = false;
        parameters.token_timestamps = false;
        parameters.language = language_utf8;
        parameters.detect_language = language_utf8 == nullptr || language_utf8[0] == '\0';

        const int status = whisper_full(
            context->whisper.get(),
            parameters,
            pcm_16khz_mono,
            static_cast<int>(sample_count));
        if (status != 0) {
            write_error(error_utf8, error_capacity, "whisper.cpp could not transcribe the in-memory PCM buffer.");
            return WITNESS_STATUS_TRANSCRIPTION_FAILED;
        }

        auto transcript = std::make_unique<witness_transcript>();
        transcript->language_id = whisper_full_lang_id(context->whisper.get());
        const int segment_count = whisper_full_n_segments(context->whisper.get());
        transcript->segments.reserve(static_cast<size_t>(std::max(0, segment_count)));
        for (int index = 0; index < segment_count; ++index) {
            const char * text = whisper_full_get_segment_text(context->whisper.get(), index);
            transcript->segments.push_back(Segment{
                text == nullptr ? std::string{} : std::string{text},
                whisper_full_get_segment_t0(context->whisper.get(), index) * 10,
                whisper_full_get_segment_t1(context->whisper.get(), index) * 10,
            });
        }

        *result = transcript.release();
        return WITNESS_STATUS_OK;
    } catch (const std::bad_alloc &) {
        write_error(error_utf8, error_capacity, "Not enough memory to transcribe this recording.");
        return WITNESS_STATUS_OUT_OF_MEMORY;
    } catch (const std::exception & error) {
        write_error(error_utf8, error_capacity, error.what());
        return WITNESS_STATUS_INTERNAL_ERROR;
    } catch (...) {
        write_error(error_utf8, error_capacity, "Unknown native error while transcribing the recording.");
        return WITNESS_STATUS_INTERNAL_ERROR;
    }
}

extern "C" void witness_transcript_destroy(witness_transcript * transcript) {
    delete transcript;
}

extern "C" int witness_transcript_language_id(const witness_transcript * transcript) {
    return transcript == nullptr ? -1 : transcript->language_id;
}

extern "C" size_t witness_transcript_segment_count(const witness_transcript * transcript) {
    return transcript == nullptr ? 0 : transcript->segments.size();
}

extern "C" const char * witness_transcript_segment_text(const witness_transcript * transcript, size_t index) {
    if (transcript == nullptr || index >= transcript->segments.size()) {
        return nullptr;
    }
    return transcript->segments[index].text.c_str();
}

extern "C" int64_t witness_transcript_segment_start_ms(const witness_transcript * transcript, size_t index) {
    if (transcript == nullptr || index >= transcript->segments.size()) {
        return -1;
    }
    return transcript->segments[index].start_ms;
}

extern "C" int64_t witness_transcript_segment_end_ms(const witness_transcript * transcript, size_t index) {
    if (transcript == nullptr || index >= transcript->segments.size()) {
        return -1;
    }
    return transcript->segments[index].end_ms;
}
