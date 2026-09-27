#include "witness_native.h"

#if !defined(_WIN32)
#error Witness WASAPI capture requires Windows.
#endif

#include <Windows.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

namespace {

template <typename T>
class com_ptr {
public:
    com_ptr() = default;
    ~com_ptr() { reset(); }
    com_ptr(const com_ptr &) = delete;
    com_ptr & operator=(const com_ptr &) = delete;

    T * get() const noexcept { return value_; }
    T ** put() noexcept {
        reset();
        return &value_;
    }
    void reset() noexcept {
        if (value_ != nullptr) value_->Release();
        value_ = nullptr;
    }
    T * operator->() const noexcept { return value_; }

private:
    T * value_ = nullptr;
};

class unique_handle {
public:
    unique_handle() = default;
    explicit unique_handle(HANDLE value) noexcept : value_(value) {}
    ~unique_handle() { reset(); }
    unique_handle(const unique_handle &) = delete;
    unique_handle & operator=(const unique_handle &) = delete;

    HANDLE get() const noexcept { return value_; }
    void reset(HANDLE value = nullptr) noexcept {
        if (value_ != nullptr) CloseHandle(value_);
        value_ = value;
    }

private:
    HANDLE value_ = nullptr;
};

void write_capture_error(char * destination, size_t capacity, const char * message) noexcept {
    if (destination == nullptr || capacity == 0) return;
    const char * safe_message = message == nullptr ? "Unknown audio capture error." : message;
    const size_t length = std::min(capacity - 1, std::strlen(safe_message));
    std::memcpy(destination, safe_message, length);
    destination[length] = '\0';
}

std::wstring utf8_to_wide(const char * value) {
    if (value == nullptr || value[0] == '\0') return {};
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
    if (length <= 1) throw std::invalid_argument("The audio endpoint ID is not valid UTF-8.");
    std::wstring result(static_cast<size_t>(length), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result.data(), length) == 0)
        throw std::invalid_argument("The audio endpoint ID is not valid UTF-8.");
    result.pop_back();
    return result;
}

witness_status map_audio_failure(HRESULT result) noexcept {
    if (result == E_ACCESSDENIED) return WITNESS_STATUS_AUDIO_ACCESS_DENIED;
    if (result == AUDCLNT_E_UNSUPPORTED_FORMAT) return WITNESS_STATUS_AUDIO_FORMAT_UNSUPPORTED;
    return WITNESS_STATUS_AUDIO_DEVICE_UNAVAILABLE;
}

bool describe_format(const WAVEFORMATEX * wave, witness_audio_format & result) noexcept {
    if (wave == nullptr || wave->nChannels == 0 || wave->nSamplesPerSec == 0) return false;
    WORD tag = wave->wFormatTag;
    WORD valid_bits = wave->wBitsPerSample;
    GUID subtype{};
    if (tag == WAVE_FORMAT_EXTENSIBLE) {
        if (wave->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) return false;
        const auto * extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(wave);
        subtype = extensible->SubFormat;
        valid_bits = extensible->Samples.wValidBitsPerSample;
        if (subtype == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) tag = WAVE_FORMAT_IEEE_FLOAT;
        else if (subtype == KSDATAFORMAT_SUBTYPE_PCM) tag = WAVE_FORMAT_PCM;
        else tag = 0;
    }

    witness_audio_sample_format format{};
    if (tag == WAVE_FORMAT_IEEE_FLOAT && wave->wBitsPerSample == 32) {
        format = WITNESS_AUDIO_FLOAT32_LE;
    } else if (tag == WAVE_FORMAT_PCM && wave->wBitsPerSample == 16) {
        format = WITNESS_AUDIO_PCM16_LE;
    } else if (tag == WAVE_FORMAT_PCM && wave->wBitsPerSample == 24) {
        format = WITNESS_AUDIO_PCM24_LE;
    } else if (tag == WAVE_FORMAT_PCM && wave->wBitsPerSample == 32 && valid_bits == 24) {
        format = WITNESS_AUDIO_PCM24_IN_32_LE;
    } else if (tag == WAVE_FORMAT_PCM && wave->wBitsPerSample == 32) {
        format = WITNESS_AUDIO_PCM32_LE;
    } else {
        return false;
    }

    const uint32_t bytes_per_sample = wave->wBitsPerSample / 8U;
    if (bytes_per_sample == 0 || wave->nBlockAlign != wave->nChannels * bytes_per_sample) return false;
    result = witness_audio_format{
        wave->nSamplesPerSec,
        wave->nChannels,
        wave->nBlockAlign,
        format,
    };
    return true;
}

}  // namespace

struct witness_audio_capture {
    std::wstring endpoint_id;
    witness_audio_packet_callback callback = nullptr;
    void * user_context = nullptr;
    unique_handle stop_event{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    unique_handle ready_event{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    std::thread worker;
    std::mutex startup_mutex;
    witness_status startup_status = WITNESS_STATUS_INTERNAL_ERROR;
    witness_audio_format startup_format{};
    std::array<char, 256> startup_error{};
    bool started = false;
};

namespace {

void finish_startup(
    witness_audio_capture * capture,
    witness_status status,
    const witness_audio_format & format,
    const char * error) noexcept {
    {
        const std::scoped_lock lock(capture->startup_mutex);
        capture->startup_status = status;
        capture->startup_format = format;
        const char * safe_error = error == nullptr ? "" : error;
        const size_t length = std::min(capture->startup_error.size() - 1, std::strlen(safe_error));
        std::memcpy(capture->startup_error.data(), safe_error, length);
        capture->startup_error[length] = '\0';
    }
    SetEvent(capture->ready_event.get());
}

void notify_interrupted(witness_audio_capture * capture) noexcept {
    capture->callback(
        capture->user_context,
        nullptr,
        0,
        0,
        WITNESS_AUDIO_PACKET_INTERRUPTED);
}

void capture_worker(witness_audio_capture * capture) noexcept {
    const HRESULT initialize_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(initialize_result)) {
        finish_startup(capture, WITNESS_STATUS_AUDIO_DEVICE_UNAVAILABLE, {}, "Windows audio COM initialization failed.");
        return;
    }

    com_ptr<IMMDeviceEnumerator> enumerator;
    com_ptr<IMMDevice> endpoint;
    com_ptr<IAudioClient> audio_client;
    com_ptr<IAudioCaptureClient> capture_client;
    unique_handle audio_event;
    WAVEFORMATEX * mix_format = nullptr;
    witness_audio_format format{};
    bool did_start = false;

    HRESULT result = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(enumerator.put()));
    if (SUCCEEDED(result)) {
        result = capture->endpoint_id.empty()
            ? enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, endpoint.put())
            : enumerator->GetDevice(capture->endpoint_id.c_str(), endpoint.put());
    }
    if (SUCCEEDED(result)) {
        result = endpoint->Activate(
            __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
            reinterpret_cast<void **>(audio_client.put()));
    }
    if (SUCCEEDED(result)) result = audio_client->GetMixFormat(&mix_format);
    if (SUCCEEDED(result) && !describe_format(mix_format, format)) result = AUDCLNT_E_UNSUPPORTED_FORMAT;
    audio_event.reset(CreateEventW(nullptr, FALSE, FALSE, nullptr));
    if (SUCCEEDED(result) && audio_event.get() == nullptr) result = HRESULT_FROM_WIN32(GetLastError());
    if (SUCCEEDED(result)) {
        result = audio_client->Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_NOPERSIST,
            0,
            0,
            mix_format,
            nullptr);
    }
    if (SUCCEEDED(result)) result = audio_client->SetEventHandle(audio_event.get());
    if (SUCCEEDED(result)) {
        result = audio_client->GetService(
            __uuidof(IAudioCaptureClient),
            reinterpret_cast<void **>(capture_client.put()));
    }
    if (SUCCEEDED(result)) result = audio_client->Start();
    if (SUCCEEDED(result)) {
        did_start = true;
        finish_startup(capture, WITNESS_STATUS_OK, format, nullptr);
    } else {
        finish_startup(capture, map_audio_failure(result), {}, "The selected microphone could not be opened.");
    }

    if (mix_format != nullptr) CoTaskMemFree(mix_format);
    if (!did_start) {
        capture_client.reset();
        audio_client.reset();
        endpoint.reset();
        enumerator.reset();
        CoUninitialize();
        return;
    }

    const std::array<HANDLE, 2> events{capture->stop_event.get(), audio_event.get()};
    bool running = true;
    while (running) {
        const DWORD wait = WaitForMultipleObjects(static_cast<DWORD>(events.size()), events.data(), FALSE, 1000);
        if (wait == WAIT_OBJECT_0) break;
        if (wait == WAIT_TIMEOUT) {
            UINT32 padding = 0;
            if (FAILED(audio_client->GetCurrentPadding(&padding))) {
                notify_interrupted(capture);
                break;
            }
            continue;
        }
        if (wait != WAIT_OBJECT_0 + 1) {
            notify_interrupted(capture);
            break;
        }

        UINT32 packet_frames = 0;
        result = capture_client->GetNextPacketSize(&packet_frames);
        while (SUCCEEDED(result) && packet_frames > 0) {
            BYTE * data = nullptr;
            DWORD flags = 0;
            UINT64 device_position = 0;
            UINT64 performance_position = 0;
            result = capture_client->GetBuffer(
                &data, &packet_frames, &flags, &device_position, &performance_position);
            if (FAILED(result)) break;

            uint32_t callback_flags = WITNESS_AUDIO_PACKET_NONE;
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) callback_flags |= WITNESS_AUDIO_PACKET_SILENT;
            if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0)
                callback_flags |= WITNESS_AUDIO_PACKET_DISCONTINUITY;
            const size_t size_bytes = static_cast<size_t>(packet_frames) * format.bytes_per_frame;
            capture->callback(
                capture->user_context,
                (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 ? nullptr : data,
                size_bytes,
                packet_frames,
                callback_flags);
            result = capture_client->ReleaseBuffer(packet_frames);
            if (FAILED(result)) break;
            result = capture_client->GetNextPacketSize(&packet_frames);
        }
        if (FAILED(result)) {
            notify_interrupted(capture);
            running = false;
        }
    }

    audio_client->Stop();
    capture_client.reset();
    audio_client.reset();
    endpoint.reset();
    enumerator.reset();
    CoUninitialize();
}

}  // namespace

extern "C" enum witness_status witness_audio_capture_create(
    const char * endpoint_id_utf8,
    witness_audio_packet_callback callback,
    void * user_context,
    witness_audio_capture ** result,
    char * error_utf8,
    size_t error_capacity) {
    if (result != nullptr) *result = nullptr;
    if (error_utf8 != nullptr && error_capacity > 0) error_utf8[0] = '\0';
    if (result == nullptr || callback == nullptr) {
        write_capture_error(error_utf8, error_capacity, "A capture result and packet callback are required.");
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    try {
        auto capture = std::make_unique<witness_audio_capture>();
        if (capture->stop_event.get() == nullptr || capture->ready_event.get() == nullptr) {
            write_capture_error(error_utf8, error_capacity, "Windows could not allocate audio capture events.");
            return WITNESS_STATUS_INTERNAL_ERROR;
        }
        capture->endpoint_id = utf8_to_wide(endpoint_id_utf8);
        capture->callback = callback;
        capture->user_context = user_context;
        *result = capture.release();
        return WITNESS_STATUS_OK;
    } catch (const std::bad_alloc &) {
        write_capture_error(error_utf8, error_capacity, "Not enough memory to create audio capture.");
        return WITNESS_STATUS_OUT_OF_MEMORY;
    } catch (const std::exception & error) {
        write_capture_error(error_utf8, error_capacity, error.what());
        return WITNESS_STATUS_INVALID_ARGUMENT;
    } catch (...) {
        write_capture_error(error_utf8, error_capacity, "Unknown error while creating audio capture.");
        return WITNESS_STATUS_INTERNAL_ERROR;
    }
}

extern "C" enum witness_status witness_audio_capture_start(
    witness_audio_capture * capture,
    witness_audio_format * format,
    char * error_utf8,
    size_t error_capacity) {
    if (error_utf8 != nullptr && error_capacity > 0) error_utf8[0] = '\0';
    if (capture == nullptr || format == nullptr || capture->started) {
        write_capture_error(error_utf8, error_capacity, "The audio capture start request is invalid.");
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    ResetEvent(capture->stop_event.get());
    ResetEvent(capture->ready_event.get());
    capture->started = true;
    try {
        capture->worker = std::thread(capture_worker, capture);
    } catch (const std::exception & error) {
        capture->started = false;
        write_capture_error(error_utf8, error_capacity, error.what());
        return WITNESS_STATUS_INTERNAL_ERROR;
    }

    const DWORD wait = WaitForSingleObject(capture->ready_event.get(), 10000);
    if (wait != WAIT_OBJECT_0) {
        SetEvent(capture->stop_event.get());
        if (capture->worker.joinable()) capture->worker.join();
        capture->started = false;
        write_capture_error(error_utf8, error_capacity, "Audio capture initialization timed out.");
        return WITNESS_STATUS_AUDIO_DEVICE_UNAVAILABLE;
    }

    witness_status status;
    std::array<char, 256> startup_error{};
    {
        const std::scoped_lock lock(capture->startup_mutex);
        status = capture->startup_status;
        *format = capture->startup_format;
        startup_error = capture->startup_error;
    }
    if (status != WITNESS_STATUS_OK) {
        if (capture->worker.joinable()) capture->worker.join();
        capture->started = false;
        write_capture_error(error_utf8, error_capacity, startup_error.data());
    }
    return status;
}

extern "C" void witness_audio_capture_stop(witness_audio_capture * capture) {
    if (capture == nullptr || !capture->started) return;
    SetEvent(capture->stop_event.get());
    if (capture->worker.joinable()) capture->worker.join();
    capture->started = false;
}

extern "C" void witness_audio_capture_destroy(witness_audio_capture * capture) {
    if (capture == nullptr) return;
    witness_audio_capture_stop(capture);
    delete capture;
}
