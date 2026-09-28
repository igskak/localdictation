#include "witness_native.h"

#include <whisper.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

struct witness_cancellation {
    std::atomic_bool cancelled{false};
};

namespace {

constexpr uint32_t kAbiVersion = 3;
constexpr size_t kMinimumSamples = 1;
constexpr size_t kMaximumSamples = 16000ULL * 600ULL;

uint32_t probe_backend_capabilities() noexcept {
    uint32_t capabilities = WITNESS_BACKEND_CPU;
#if WITNESS_NATIVE_HAS_VULKAN
    capabilities |= WITNESS_BACKEND_VULKAN_COMPILED;
#endif
    try {
        for (size_t index = 0; index < ggml_backend_dev_count(); ++index) {
            ggml_backend_dev_t device = ggml_backend_dev_get(index);
            const auto type = ggml_backend_dev_type(device);
            if (type != GGML_BACKEND_DEVICE_TYPE_GPU && type != GGML_BACKEND_DEVICE_TYPE_IGPU) {
                continue;
            }
            capabilities |= WITNESS_BACKEND_GPU_DEVICE;
            ggml_backend_t backend = ggml_backend_dev_init(device, nullptr);
            if (backend != nullptr) {
                capabilities |= WITNESS_BACKEND_GPU_INITIALIZED;
                ggml_backend_free(backend);
                break;
            }
        }
    } catch (...) {
        // A driver/backend probe is optional. CPU remains available and the
        // caller must not interpret a device name as successful initialization.
    }
    return capabilities;
}

struct WhisperDeleter {
    void operator()(whisper_context * value) const noexcept {
        if (value != nullptr) {
            whisper_free(value);
        }
    }
};

struct Token {
    std::string text;
    float probability;
};

struct Segment {
    std::string text;
    int64_t start_ms;
    int64_t end_ms;
    std::vector<Token> tokens;
};

struct LanguageScore {
    std::string code;
    float probability;
};

bool should_abort(void * user_context) noexcept {
    const auto * cancellation = static_cast<const witness_cancellation *>(user_context);
    return cancellation != nullptr && cancellation->cancelled.load(std::memory_order_relaxed);
}

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
    bool uses_gpu = false;
};

struct witness_transcript {
    int language_id = -1;
    std::string language;
    std::vector<Segment> segments;
};

struct witness_language_scores {
    std::vector<LanguageScore> values;
};

extern "C" uint32_t witness_native_abi_version(void) {
    return kAbiVersion;
}

extern "C" uint32_t witness_backend_capabilities(void) {
    return probe_backend_capabilities();
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
    if (use_gpu != 0
        && (probe_backend_capabilities() & WITNESS_BACKEND_GPU_INITIALIZED) == 0) {
        write_error(error_utf8, error_capacity, "No compatible GPU backend could be initialized.");
        return WITNESS_STATUS_BACKEND_UNAVAILABLE;
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
        owned->uses_gpu = use_gpu != 0;
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

extern "C" int witness_context_uses_gpu(const witness_context * context) {
    return context != nullptr && context->uses_gpu ? 1 : 0;
}

extern "C" enum witness_status witness_cancellation_create(witness_cancellation ** result) {
    if (result == nullptr) {
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    *result = nullptr;
    try {
        *result = new witness_cancellation();
        return WITNESS_STATUS_OK;
    } catch (const std::bad_alloc &) {
        return WITNESS_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return WITNESS_STATUS_INTERNAL_ERROR;
    }
}

extern "C" void witness_cancellation_cancel(witness_cancellation * cancellation) {
    if (cancellation != nullptr) {
        cancellation->cancelled.store(true, std::memory_order_relaxed);
    }
}

extern "C" void witness_cancellation_destroy(witness_cancellation * cancellation) {
    delete cancellation;
}

extern "C" enum witness_status witness_detect_languages(
    witness_context * context,
    const float * pcm_16khz_mono,
    size_t sample_count,
    int thread_count,
    witness_cancellation * cancellation,
    witness_language_scores ** result,
    char * error_utf8,
    size_t error_capacity) {
    clear_error(error_utf8, error_capacity);
    if (result != nullptr) {
        *result = nullptr;
    }
    if (result == nullptr || context == nullptr || context->whisper == nullptr || pcm_16khz_mono == nullptr
        || sample_count < kMinimumSamples || sample_count > kMaximumSamples || thread_count < 1) {
        write_error(error_utf8, error_capacity, "The language detection request is invalid.");
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    if (whisper_is_multilingual(context->whisper.get()) == 0) {
        write_error(error_utf8, error_capacity, "The selected speech model does not support language detection.");
        return WITNESS_STATUS_LANGUAGE_DETECTION_FAILED;
    }
    if (should_abort(cancellation)) {
        write_error(error_utf8, error_capacity, "Language detection was cancelled.");
        return WITNESS_STATUS_CANCELLED;
    }

    try {
        // The complete finished recording is supplied here. whisper.cpp builds
        // the mel input from that buffer before evaluating its normal language
        // window at offset zero, so leading-silence behavior can be measured.
        if (whisper_pcm_to_mel(
                context->whisper.get(),
                pcm_16khz_mono,
                static_cast<int>(sample_count),
                thread_count) != 0) {
            write_error(error_utf8, error_capacity, "whisper.cpp could not prepare audio for language detection.");
            return WITNESS_STATUS_LANGUAGE_DETECTION_FAILED;
        }
        if (should_abort(cancellation)) {
            write_error(error_utf8, error_capacity, "Language detection was cancelled.");
            return WITNESS_STATUS_CANCELLED;
        }

        const int maximum_language_id = whisper_lang_max_id();
        if (maximum_language_id < 0) {
            write_error(error_utf8, error_capacity, "whisper.cpp reported no detectable languages.");
            return WITNESS_STATUS_LANGUAGE_DETECTION_FAILED;
        }
        std::vector<float> probabilities(static_cast<size_t>(maximum_language_id) + 1U, 0.0F);
        if (whisper_lang_auto_detect(
                context->whisper.get(),
                0,
                thread_count,
                probabilities.data()) < 0) {
            write_error(error_utf8, error_capacity, "whisper.cpp could not detect the recording language.");
            return WITNESS_STATUS_LANGUAGE_DETECTION_FAILED;
        }
        if (should_abort(cancellation)) {
            write_error(error_utf8, error_capacity, "Language detection was cancelled.");
            return WITNESS_STATUS_CANCELLED;
        }

        auto scores = std::make_unique<witness_language_scores>();
        scores->values.reserve(probabilities.size());
        for (int language_id = 0; language_id <= maximum_language_id; ++language_id) {
            const char * code = whisper_lang_str(language_id);
            const float probability = probabilities[static_cast<size_t>(language_id)];
            if (code == nullptr || code[0] == '\0' || !std::isfinite(probability)) {
                continue;
            }
            scores->values.push_back(LanguageScore{
                std::string{code},
                std::clamp(probability, 0.0F, 1.0F),
            });
        }
        if (scores->values.empty()) {
            write_error(error_utf8, error_capacity, "whisper.cpp returned no valid language scores.");
            return WITNESS_STATUS_LANGUAGE_DETECTION_FAILED;
        }

        *result = scores.release();
        return WITNESS_STATUS_OK;
    } catch (const std::bad_alloc &) {
        write_error(error_utf8, error_capacity, "Not enough memory to detect the recording language.");
        return WITNESS_STATUS_OUT_OF_MEMORY;
    } catch (const std::exception & error) {
        write_error(error_utf8, error_capacity, error.what());
        return WITNESS_STATUS_INTERNAL_ERROR;
    } catch (...) {
        write_error(error_utf8, error_capacity, "Unknown native error while detecting the recording language.");
        return WITNESS_STATUS_INTERNAL_ERROR;
    }
}

extern "C" void witness_language_scores_destroy(witness_language_scores * scores) {
    delete scores;
}

extern "C" size_t witness_language_scores_count(const witness_language_scores * scores) {
    return scores == nullptr ? 0 : scores->values.size();
}

extern "C" const char * witness_language_score_code(
    const witness_language_scores * scores,
    size_t index) {
    if (scores == nullptr || index >= scores->values.size()) {
        return nullptr;
    }
    return scores->values[index].code.c_str();
}

extern "C" float witness_language_score_probability(
    const witness_language_scores * scores,
    size_t index) {
    if (scores == nullptr || index >= scores->values.size()) {
        return 0.0F;
    }
    return scores->values[index].probability;
}

extern "C" enum witness_status witness_transcribe_cancelable(
    witness_context * context,
    const float * pcm_16khz_mono,
    size_t sample_count,
    const char * language_utf8,
    int thread_count,
    witness_cancellation * cancellation,
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
    if (should_abort(cancellation)) {
        write_error(error_utf8, error_capacity, "The transcription was cancelled.");
        return WITNESS_STATUS_CANCELLED;
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
        parameters.abort_callback = cancellation == nullptr ? nullptr : should_abort;
        parameters.abort_callback_user_data = cancellation;

        const int status = whisper_full(
            context->whisper.get(),
            parameters,
            pcm_16khz_mono,
            static_cast<int>(sample_count));
        if (should_abort(cancellation)) {
            write_error(error_utf8, error_capacity, "The transcription was cancelled.");
            return WITNESS_STATUS_CANCELLED;
        }
        if (status != 0) {
            write_error(error_utf8, error_capacity, "whisper.cpp could not transcribe the in-memory PCM buffer.");
            return WITNESS_STATUS_TRANSCRIPTION_FAILED;
        }

        auto transcript = std::make_unique<witness_transcript>();
        transcript->language_id = whisper_full_lang_id(context->whisper.get());
        const char * language = whisper_lang_str(transcript->language_id);
        transcript->language = language == nullptr ? std::string{} : std::string{language};
        const int segment_count = whisper_full_n_segments(context->whisper.get());
        transcript->segments.reserve(static_cast<size_t>(std::max(0, segment_count)));
        for (int index = 0; index < segment_count; ++index) {
            const char * text = whisper_full_get_segment_text(context->whisper.get(), index);
            Segment segment{
                text == nullptr ? std::string{} : std::string{text},
                whisper_full_get_segment_t0(context->whisper.get(), index) * 10,
                whisper_full_get_segment_t1(context->whisper.get(), index) * 10,
                {},
            };
            const int token_count = whisper_full_n_tokens(context->whisper.get(), index);
            segment.tokens.reserve(static_cast<size_t>(std::max(0, token_count)));
            const whisper_token first_special = whisper_token_eot(context->whisper.get());
            for (int token_index = 0; token_index < token_count; ++token_index) {
                const whisper_token token_id = whisper_full_get_token_id(
                    context->whisper.get(), index, token_index);
                if (token_id >= first_special) {
                    continue;
                }
                const char * token_text = whisper_full_get_token_text(
                    context->whisper.get(), index, token_index);
                if (token_text == nullptr || token_text[0] == '\0') {
                    continue;
                }
                segment.tokens.push_back(Token{
                    std::string{token_text},
                    whisper_full_get_token_p(context->whisper.get(), index, token_index),
                });
            }
            transcript->segments.push_back(std::move(segment));
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

extern "C" enum witness_status witness_transcribe(
    witness_context * context,
    const float * pcm_16khz_mono,
    size_t sample_count,
    const char * language_utf8,
    int thread_count,
    witness_transcript ** result,
    char * error_utf8,
    size_t error_capacity) {
    return witness_transcribe_cancelable(
        context,
        pcm_16khz_mono,
        sample_count,
        language_utf8,
        thread_count,
        nullptr,
        result,
        error_utf8,
        error_capacity);
}

extern "C" void witness_transcript_destroy(witness_transcript * transcript) {
    delete transcript;
}

extern "C" int witness_transcript_language_id(const witness_transcript * transcript) {
    return transcript == nullptr ? -1 : transcript->language_id;
}

extern "C" const char * witness_transcript_language(const witness_transcript * transcript) {
    return transcript == nullptr ? nullptr : transcript->language.c_str();
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

extern "C" size_t witness_transcript_segment_token_count(
    const witness_transcript * transcript,
    size_t segment_index) {
    if (transcript == nullptr || segment_index >= transcript->segments.size()) {
        return 0;
    }
    return transcript->segments[segment_index].tokens.size();
}

extern "C" const char * witness_transcript_token_text(
    const witness_transcript * transcript,
    size_t segment_index,
    size_t token_index) {
    if (transcript == nullptr || segment_index >= transcript->segments.size()
        || token_index >= transcript->segments[segment_index].tokens.size()) {
        return nullptr;
    }
    return transcript->segments[segment_index].tokens[token_index].text.c_str();
}

extern "C" float witness_transcript_token_probability(
    const witness_transcript * transcript,
    size_t segment_index,
    size_t token_index) {
    if (transcript == nullptr || segment_index >= transcript->segments.size()
        || token_index >= transcript->segments[segment_index].tokens.size()) {
        return 0.0F;
    }
    return transcript->segments[segment_index].tokens[token_index].probability;
}

extern "C" int64_t witness_transcript_token_start_ms(
    const witness_transcript *,
    size_t,
    size_t) {
    return -1;
}

extern "C" int64_t witness_transcript_token_end_ms(
    const witness_transcript *,
    size_t,
    size_t) {
    return -1;
}
