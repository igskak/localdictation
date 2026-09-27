#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
  #if defined(WITNESS_NATIVE_BUILD)
    #define WITNESS_NATIVE_API __declspec(dllexport)
  #else
    #define WITNESS_NATIVE_API __declspec(dllimport)
  #endif
#else
  #define WITNESS_NATIVE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct witness_context witness_context;
typedef struct witness_transcript witness_transcript;

enum witness_status {
    WITNESS_STATUS_OK = 0,
    WITNESS_STATUS_INVALID_ARGUMENT = 1,
    WITNESS_STATUS_MODEL_LOAD_FAILED = 2,
    WITNESS_STATUS_TRANSCRIPTION_FAILED = 3,
    WITNESS_STATUS_OUT_OF_MEMORY = 4,
    WITNESS_STATUS_INTERNAL_ERROR = 5,
};

WITNESS_NATIVE_API uint32_t witness_native_abi_version(void);

WITNESS_NATIVE_API enum witness_status witness_context_create(
    const char * model_path_utf8,
    int use_gpu,
    witness_context ** result,
    char * error_utf8,
    size_t error_capacity);

WITNESS_NATIVE_API void witness_context_destroy(witness_context * context);

WITNESS_NATIVE_API enum witness_status witness_transcribe(
    witness_context * context,
    const float * pcm_16khz_mono,
    size_t sample_count,
    const char * language_utf8,
    int thread_count,
    witness_transcript ** result,
    char * error_utf8,
    size_t error_capacity);

WITNESS_NATIVE_API void witness_transcript_destroy(witness_transcript * transcript);
WITNESS_NATIVE_API int witness_transcript_language_id(const witness_transcript * transcript);
WITNESS_NATIVE_API size_t witness_transcript_segment_count(const witness_transcript * transcript);
WITNESS_NATIVE_API const char * witness_transcript_segment_text(const witness_transcript * transcript, size_t index);
WITNESS_NATIVE_API int64_t witness_transcript_segment_start_ms(const witness_transcript * transcript, size_t index);
WITNESS_NATIVE_API int64_t witness_transcript_segment_end_ms(const witness_transcript * transcript, size_t index);

#ifdef __cplusplus
}
#endif
