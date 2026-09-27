#include "witness_native.h"

#if !defined(_WIN32)
#error Witness audio device enumeration requires Windows.
#endif

#define NOMINMAX
#include <Windows.h>
#include <initguid.h>
#include <propkeydef.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

template <typename T>
class device_com_ptr {
public:
    device_com_ptr() = default;
    ~device_com_ptr() { reset(); }
    device_com_ptr(const device_com_ptr &) = delete;
    device_com_ptr & operator=(const device_com_ptr &) = delete;

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

class device_com_session {
public:
    device_com_session() {
        const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (SUCCEEDED(result)) uninitialize_ = true;
        else if (result != RPC_E_CHANGED_MODE) throw std::runtime_error("Windows audio COM initialization failed.");
    }
    ~device_com_session() {
        if (uninitialize_) CoUninitialize();
    }
    device_com_session(const device_com_session &) = delete;
    device_com_session & operator=(const device_com_session &) = delete;

private:
    bool uninitialize_ = false;
};

struct device_record {
    std::string id;
    std::string name;
    bool is_default = false;
    witness_audio_device_location location = WITNESS_AUDIO_DEVICE_LOCATION_UNKNOWN;
};

void write_device_error(char * destination, size_t capacity, const char * message) noexcept {
    if (destination == nullptr || capacity == 0) return;
    const char * safe_message = message == nullptr ? "Unknown audio device error." : message;
    const size_t length = std::min(capacity - 1, std::strlen(safe_message));
    std::memcpy(destination, safe_message, length);
    destination[length] = '\0';
}

std::string wide_to_utf8(const wchar_t * value) {
    if (value == nullptr || value[0] == L'\0') return {};
    const int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
    if (required <= 1) throw std::runtime_error("Windows returned an invalid audio device string.");
    std::string result(static_cast<size_t>(required), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result.data(), required, nullptr, nullptr) == 0)
        throw std::runtime_error("Windows returned an invalid audio device string.");
    result.pop_back();
    return result;
}

std::string read_string_property(IPropertyStore * store, const PROPERTYKEY & key) {
    if (store == nullptr) return {};
    PROPVARIANT value;
    PropVariantInit(&value);
    const HRESULT result = store->GetValue(key, &value);
    std::string text;
    if (SUCCEEDED(result) && value.vt == VT_LPWSTR) text = wide_to_utf8(value.pwszVal);
    PropVariantClear(&value);
    return text;
}

std::wstring endpoint_id(IMMDevice * device) {
    LPWSTR value = nullptr;
    if (FAILED(device->GetId(&value)) || value == nullptr) throw std::runtime_error("Windows did not return an endpoint ID.");
    std::wstring result{value};
    CoTaskMemFree(value);
    return result;
}

}  // namespace

struct witness_audio_device_list {
    std::vector<device_record> devices;
};

extern "C" enum witness_status witness_audio_device_list_create(
    witness_audio_device_list ** result,
    char * error_utf8,
    size_t error_capacity) {
    if (result != nullptr) *result = nullptr;
    if (error_utf8 != nullptr && error_capacity > 0) error_utf8[0] = '\0';
    if (result == nullptr) {
        write_device_error(error_utf8, error_capacity, "An audio device-list result is required.");
        return WITNESS_STATUS_INVALID_ARGUMENT;
    }
    try {
        device_com_session session;
        device_com_ptr<IMMDeviceEnumerator> enumerator;
        HRESULT status = CoCreateInstance(
            __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(enumerator.put()));
        if (FAILED(status)) throw std::runtime_error("Windows audio device enumeration is unavailable.");

        std::wstring default_id;
        device_com_ptr<IMMDevice> default_device;
        if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, default_device.put())))
            default_id = endpoint_id(default_device.get());

        device_com_ptr<IMMDeviceCollection> collection;
        status = enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, collection.put());
        if (FAILED(status)) throw std::runtime_error("Windows could not enumerate active microphones.");
        UINT count = 0;
        if (FAILED(collection->GetCount(&count))) throw std::runtime_error("Windows could not count active microphones.");

        auto list = std::make_unique<witness_audio_device_list>();
        list->devices.reserve(count);
        for (UINT index = 0; index < count; ++index) {
            device_com_ptr<IMMDevice> device;
            if (FAILED(collection->Item(index, device.put()))) continue;
            const std::wstring ordinary_id = endpoint_id(device.get());
            device_com_ptr<IPropertyStore> properties;
            if (FAILED(device->OpenPropertyStore(STGM_READ, properties.put()))) continue;

            std::string name = read_string_property(properties.get(), PKEY_Device_FriendlyName);
            if (name.empty()) name = "Microphone";
            list->devices.push_back(device_record{
                wide_to_utf8(ordinary_id.c_str()),
                std::move(name),
                ordinary_id == default_id,
                WITNESS_AUDIO_DEVICE_LOCATION_UNKNOWN,
            });
        }
        *result = list.release();
        return WITNESS_STATUS_OK;
    } catch (const std::bad_alloc &) {
        write_device_error(error_utf8, error_capacity, "Not enough memory to list microphones.");
        return WITNESS_STATUS_OUT_OF_MEMORY;
    } catch (const std::exception & error) {
        write_device_error(error_utf8, error_capacity, error.what());
        return WITNESS_STATUS_AUDIO_DEVICE_UNAVAILABLE;
    } catch (...) {
        write_device_error(error_utf8, error_capacity, "Unknown error while listing microphones.");
        return WITNESS_STATUS_INTERNAL_ERROR;
    }
}

extern "C" void witness_audio_device_list_destroy(witness_audio_device_list * list) {
    delete list;
}

extern "C" size_t witness_audio_device_list_count(const witness_audio_device_list * list) {
    return list == nullptr ? 0 : list->devices.size();
}

extern "C" const char * witness_audio_device_id(const witness_audio_device_list * list, size_t index) {
    return list == nullptr || index >= list->devices.size() ? nullptr : list->devices[index].id.c_str();
}

extern "C" const char * witness_audio_device_name(const witness_audio_device_list * list, size_t index) {
    return list == nullptr || index >= list->devices.size() ? nullptr : list->devices[index].name.c_str();
}

extern "C" int witness_audio_device_is_default(const witness_audio_device_list * list, size_t index) {
    return list != nullptr && index < list->devices.size() && list->devices[index].is_default ? 1 : 0;
}

extern "C" enum witness_audio_device_location witness_audio_device_location_value(
    const witness_audio_device_list * list,
    size_t index) {
    return list == nullptr || index >= list->devices.size()
        ? WITNESS_AUDIO_DEVICE_LOCATION_UNKNOWN
        : list->devices[index].location;
}
