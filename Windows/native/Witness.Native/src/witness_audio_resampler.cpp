#include "witness_native.h"

#if !defined(_WIN32)
#error Witness Media Foundation resampling requires Windows.
#endif

#define NOMINMAX
#include <Windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <wmcodecdsp.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <stdexcept>
#include <vector>

namespace {

constexpr uint32_t kOutputSampleRate = 16000;
constexpr size_t kMaximumDurationSeconds = 600;
constexpr size_t kInputChunkSamples = 4096;
constexpr DWORD kOutputBufferBytes = 64 * 1024;

template <typename T>
class mf_com_ptr {
public:
    mf_com_ptr() = default;
    ~mf_com_ptr() { reset(); }
    mf_com_ptr(const mf_com_ptr &) = delete;
    mf_com_ptr & operator=(const mf_com_ptr &) = delete;
    mf_com_ptr(mf_com_ptr && other) noexcept : value_(other.value_) { other.value_ = nullptr; }
    mf_com_ptr & operator=(mf_com_ptr && other) noexcept {
        if (this != &other) {
            reset();
            value_ = other.value_;
            other.value_ = nullptr;
        }
        return *this;
    }

    T * get() const noexcept { return value_; }
    T ** put() noexcept {
        reset();
        return &value_;
    }
    void attach(T * value) noexcept {
        reset();
        value_ = value;
    }
    void reset() noexcept {
        if (value_ != nullptr) value_->Release();
        value_ = nullptr;
    }
    T * operator->() const noexcept { return value_; }

private:
    T * value_ = nullptr;
};

class media_foundation_session {
public:
    media_foundation_session() {
        const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (SUCCEEDED(com_result)) uninitialize_com_ = true;
        else if (com_result != RPC_E_CHANGED_MODE) throw std::runtime_error("COM initialization failed.");
        const HRESULT mf_result = MFStartup(MF_VERSION, MFSTARTUP_LITE);
        if (FAILED(mf_result)) throw std::runtime_error("Media Foundation initialization failed.");
        started_ = true;
    }

    ~media_foundation_session() {
        if (started_) MFShutdown();
        if (uninitialize_com_) CoUninitialize();
    }

    media_foundation_session(const media_foundation_session &) = delete;
    media_foundation_session & operator=(const media_foundation_session &) = delete;

private:
    bool started_ = false;
    bool uninitialize_com_ = false;
};

void check(HRESULT result, const char * message) {
    if (FAILED(result)) throw std::runtime_error(message);
}

void write_resample_error(char * destination, size_t capacity, const char * message) noexcept {
    if (destination == nullptr || capacity == 0) return;
    const char * safe_message = message == nullptr ? "Unknown audio resampling error." : message;
    const size_t length = std::min(capacity - 1, std::strlen(safe_message));
    std::memcpy(destination, safe_message, length);
    destination[length] = '\0';
}

mf_com_ptr<IMFMediaType> make_float_mono_type(uint32_t sample_rate) {
    mf_com_ptr<IMFMediaType> type;
    check(MFCreateMediaType(type.put()), "Could not create an audio media type.");
    check(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), "Could not set the audio major type.");
    check(type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float), "Could not set the Float32 audio type.");
    check(type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1), "Could not set the audio channel count.");
    check(type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate), "Could not set the audio sample rate.");
    check(type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, static_cast<uint32_t>(sizeof(float))),
        "Could not set audio block alignment.");
    check(type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, sample_rate * static_cast<uint32_t>(sizeof(float))),
        "Could not set the audio byte rate.");
    check(type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 32), "Could not set the audio bit depth.");
    check(type->SetUINT32(MF_MT_AUDIO_CHANNEL_MASK, SPEAKER_FRONT_CENTER), "Could not set the audio channel mask.");
    check(type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE), "Could not set the audio sample independence.");
    return type;
}

mf_com_ptr<IMFSample> make_input_sample(const float * input, size_t count, LONGLONG time, uint32_t rate) {
    const size_t byte_count = count * sizeof(float);
    if (byte_count > MAXDWORD) throw std::runtime_error("An audio resampler input chunk is too large.");
    mf_com_ptr<IMFMediaBuffer> buffer;
    check(MFCreateMemoryBuffer(static_cast<DWORD>(byte_count), buffer.put()), "Could not allocate an audio input buffer.");
    BYTE * destination = nullptr;
    DWORD capacity = 0;
    check(buffer->Lock(&destination, &capacity, nullptr), "Could not lock an audio input buffer.");
    if (capacity < byte_count) {
        buffer->Unlock();
        throw std::runtime_error("The audio input buffer is smaller than requested.");
    }
    std::memcpy(destination, input, byte_count);
    check(buffer->Unlock(), "Could not unlock an audio input buffer.");
    check(buffer->SetCurrentLength(static_cast<DWORD>(byte_count)), "Could not commit an audio input buffer.");

    mf_com_ptr<IMFSample> sample;
    check(MFCreateSample(sample.put()), "Could not create an audio input sample.");
    check(sample->AddBuffer(buffer.get()), "Could not attach the audio input buffer.");
    check(sample->SetSampleTime(time), "Could not set the audio input timestamp.");
    const LONGLONG duration = static_cast<LONGLONG>(count * 10'000'000ULL / rate);
    check(sample->SetSampleDuration(duration), "Could not set the audio input duration.");
    return sample;
}

bool pull_output(IMFTransform * transform, std::vector<float> & output) {
    MFT_OUTPUT_STREAM_INFO stream_info{};
    check(transform->GetOutputStreamInfo(0, &stream_info), "Could not query the resampler output stream.");

    mf_com_ptr<IMFSample> supplied_sample;
    if ((stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0) {
        mf_com_ptr<IMFMediaBuffer> buffer;
        const DWORD buffer_size = std::max(kOutputBufferBytes, stream_info.cbSize);
        check(MFCreateMemoryBuffer(buffer_size, buffer.put()), "Could not allocate a resampler output buffer.");
        check(MFCreateSample(supplied_sample.put()), "Could not create a resampler output sample.");
        check(supplied_sample->AddBuffer(buffer.get()), "Could not attach the resampler output buffer.");
    }

    MFT_OUTPUT_DATA_BUFFER output_data{};
    output_data.dwStreamID = 0;
    output_data.pSample = supplied_sample.get();
    DWORD status = 0;
    const HRESULT result = transform->ProcessOutput(0, 1, &output_data, &status);
    if (output_data.pEvents != nullptr) output_data.pEvents->Release();
    if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) return false;
    check(result, "Media Foundation could not produce resampled audio.");

    mf_com_ptr<IMFSample> provided_sample;
    IMFSample * sample = output_data.pSample;
    if (sample != supplied_sample.get()) provided_sample.attach(sample);
    if (sample == nullptr) throw std::runtime_error("The audio resampler returned no output sample.");

    mf_com_ptr<IMFMediaBuffer> contiguous;
    check(sample->ConvertToContiguousBuffer(contiguous.put()), "Could not read the resampler output.");
    BYTE * bytes = nullptr;
    DWORD length = 0;
    check(contiguous->Lock(&bytes, nullptr, &length), "Could not lock the resampler output.");
    if (length % sizeof(float) != 0) {
        contiguous->Unlock();
        throw std::runtime_error("The resampler returned a partial Float32 sample.");
    }
    const size_t old_size = output.size();
    output.resize(old_size + length / sizeof(float));
    std::memcpy(output.data() + old_size, bytes, length);
    check(contiguous->Unlock(), "Could not unlock the resampler output.");
    return true;
}

void drain_available(IMFTransform * transform, std::vector<float> & output) {
    while (pull_output(transform, output)) { }
}

std::vector<float> resample(const float * input, size_t count, uint32_t rate) {
    media_foundation_session session;
    mf_com_ptr<IMFTransform> transform;
    check(CoCreateInstance(
        CLSID_CResamplerMediaObject,
        nullptr,
        CLSCTX_INPROC_SERVER,
        __uuidof(IMFTransform),
        reinterpret_cast<void **>(transform.put())),
        "The Windows audio resampler is unavailable.");

    mf_com_ptr<IWMResamplerProps> properties;
    if (SUCCEEDED(transform->QueryInterface(__uuidof(IWMResamplerProps), reinterpret_cast<void **>(properties.put()))))
        check(properties->SetHalfFilterLength(60), "Could not set the resampler quality.");

    auto input_type = make_float_mono_type(rate);
    auto output_type = make_float_mono_type(kOutputSampleRate);
    check(transform->SetInputType(0, input_type.get(), 0), "The resampler rejected its input format.");
    check(transform->SetOutputType(0, output_type.get(), 0), "The resampler rejected its output format.");
    check(transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0), "Could not begin audio resampling.");
    check(transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0), "Could not start the audio resampler.");

    std::vector<float> output;
    output.reserve(count * kOutputSampleRate / rate + 1024);
    size_t offset = 0;
    while (offset < count) {
        const size_t chunk = std::min(kInputChunkSamples, count - offset);
        const LONGLONG time = static_cast<LONGLONG>(offset * 10'000'000ULL / rate);
        auto sample = make_input_sample(input + offset, chunk, time, rate);
        HRESULT result = transform->ProcessInput(0, sample.get(), 0);
        if (result == MF_E_NOTACCEPTING) {
            drain_available(transform.get(), output);
            result = transform->ProcessInput(0, sample.get(), 0);
        }
        check(result, "Media Foundation could not accept audio for resampling.");
        offset += chunk;
        drain_available(transform.get(), output);
    }

    check(transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0), "Could not end the resampler input stream.");
    check(transform->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0), "Could not drain the audio resampler.");
    drain_available(transform.get(), output);
    check(transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0), "Could not finish audio resampling.");
    return output;
}

}  // namespace

struct witness_audio_buffer {
    std::vector<float> samples;
};

extern "C" enum witness_status witness_audio_resample_to_16khz(
    const float * input_mono,
    size_t input_sample_count,
    uint32_t input_sample_rate,
    witness_audio_buffer ** result,
    char * error_utf8,
    size_t error_capacity) {
    if (result != nullptr) *result = nullptr;
    if (error_utf8 != nullptr && error_capacity > 0) error_utf8[0] = '\0';
    if (result == nullptr || input_mono == nullptr || input_sample_count == 0 ||
        input_sample_rate < 8000 || input_sample_rate > 192000 ||
        input_sample_count > static_cast<size_t>(input_sample_rate) * kMaximumDurationSeconds) {
        write_resample_error(error_utf8, error_capacity, "The audio resampling request is invalid.");
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    try {
        auto buffer = std::make_unique<witness_audio_buffer>();
        buffer->samples = resample(input_mono, input_sample_count, input_sample_rate);
        if (buffer->samples.empty()) {
            write_resample_error(error_utf8, error_capacity, "The audio resampler returned no samples.");
            return WITNESS_STATUS_INTERNAL_ERROR;
        }
        *result = buffer.release();
        return WITNESS_STATUS_OK;
    } catch (const std::bad_alloc &) {
        write_resample_error(error_utf8, error_capacity, "Not enough memory to resample this recording.");
        return WITNESS_STATUS_OUT_OF_MEMORY;
    } catch (const std::exception & error) {
        write_resample_error(error_utf8, error_capacity, error.what());
        return WITNESS_STATUS_INTERNAL_ERROR;
    } catch (...) {
        write_resample_error(error_utf8, error_capacity, "Unknown error while resampling audio.");
        return WITNESS_STATUS_INTERNAL_ERROR;
    }
}

extern "C" const float * witness_audio_buffer_data(const witness_audio_buffer * buffer) {
    return buffer == nullptr || buffer->samples.empty() ? nullptr : buffer->samples.data();
}

extern "C" size_t witness_audio_buffer_sample_count(const witness_audio_buffer * buffer) {
    return buffer == nullptr ? 0 : buffer->samples.size();
}

extern "C" void witness_audio_buffer_destroy(witness_audio_buffer * buffer) {
    delete buffer;
}
