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
    WITNESS_STATUS_AUDIO_ACCESS_DENIED = 6,
    WITNESS_STATUS_AUDIO_DEVICE_UNAVAILABLE = 7,
    WITNESS_STATUS_AUDIO_FORMAT_UNSUPPORTED = 8,
};

enum witness_audio_sample_format {
    WITNESS_AUDIO_PCM16_LE = 1,
    WITNESS_AUDIO_PCM24_LE = 2,
    WITNESS_AUDIO_PCM32_LE = 3,
    WITNESS_AUDIO_FLOAT32_LE = 4,
    WITNESS_AUDIO_PCM24_IN_32_LE = 5,
};

typedef struct witness_audio_capture witness_audio_capture;
typedef struct witness_audio_buffer witness_audio_buffer;
typedef struct witness_audio_device_list witness_audio_device_list;

struct witness_audio_format {
    uint32_t sample_rate;
    uint32_t channel_count;
    uint32_t bytes_per_frame;
    enum witness_audio_sample_format sample_format;
};

enum witness_audio_packet_flags {
    WITNESS_AUDIO_PACKET_NONE = 0,
    WITNESS_AUDIO_PACKET_SILENT = 1,
    WITNESS_AUDIO_PACKET_DISCONTINUITY = 2,
    WITNESS_AUDIO_PACKET_INTERRUPTED = 4,
};

enum witness_audio_device_location {
    WITNESS_AUDIO_DEVICE_LOCATION_UNKNOWN = 0,
    WITNESS_AUDIO_DEVICE_LOCATION_BUILT_IN = 1,
    WITNESS_AUDIO_DEVICE_LOCATION_EXTERNAL = 2,
};

typedef void (*witness_audio_packet_callback)(
    void * user_context,
    const void * data,
    size_t size_bytes,
    size_t frame_count,
    uint32_t flags);

WITNESS_NATIVE_API uint32_t witness_native_abi_version(void);

// Converts complete interleaved frames to mono Float32 without retaining the
// source. The output capacity and returned frame count are measured in floats.
WITNESS_NATIVE_API enum witness_status witness_audio_decode_to_mono(
    const void * input,
    size_t input_size_bytes,
    size_t frame_count,
    uint32_t channel_count,
    enum witness_audio_sample_format format,
    float * output,
    size_t output_capacity_frames,
    size_t * output_frame_count);

// Captures shared-mode input with an event-driven WASAPI worker. Packet memory
// is valid only during the callback and must be copied into a bounded queue.
// No audio data is written to disk or retained after ReleaseBuffer.
WITNESS_NATIVE_API enum witness_status witness_audio_capture_create(
    const char * endpoint_id_utf8,
    witness_audio_packet_callback callback,
    void * user_context,
    witness_audio_capture ** result,
    char * error_utf8,
    size_t error_capacity);

WITNESS_NATIVE_API enum witness_status witness_audio_capture_start(
    witness_audio_capture * capture,
    struct witness_audio_format * format,
    char * error_utf8,
    size_t error_capacity);

WITNESS_NATIVE_API void witness_audio_capture_stop(witness_audio_capture * capture);
WITNESS_NATIVE_API void witness_audio_capture_destroy(witness_audio_capture * capture);

// Runs on a worker after capture, never from the WASAPI packet callback. Input
// and output stay in memory. The caller owns the returned buffer until destroy.
WITNESS_NATIVE_API enum witness_status witness_audio_resample_to_16khz(
    const float * input_mono,
    size_t input_sample_count,
    uint32_t input_sample_rate,
    witness_audio_buffer ** result,
    char * error_utf8,
    size_t error_capacity);

WITNESS_NATIVE_API const float * witness_audio_buffer_data(const witness_audio_buffer * buffer);
WITNESS_NATIVE_API size_t witness_audio_buffer_sample_count(const witness_audio_buffer * buffer);
WITNESS_NATIVE_API void witness_audio_buffer_destroy(witness_audio_buffer * buffer);

WITNESS_NATIVE_API enum witness_status witness_audio_device_list_create(
    witness_audio_device_list ** result,
    char * error_utf8,
    size_t error_capacity);
WITNESS_NATIVE_API void witness_audio_device_list_destroy(witness_audio_device_list * list);
WITNESS_NATIVE_API size_t witness_audio_device_list_count(const witness_audio_device_list * list);
WITNESS_NATIVE_API const char * witness_audio_device_id(const witness_audio_device_list * list, size_t index);
WITNESS_NATIVE_API const char * witness_audio_device_name(const witness_audio_device_list * list, size_t index);
WITNESS_NATIVE_API int witness_audio_device_is_default(const witness_audio_device_list * list, size_t index);
WITNESS_NATIVE_API enum witness_audio_device_location witness_audio_device_location_value(
    const witness_audio_device_list * list,
    size_t index);

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
