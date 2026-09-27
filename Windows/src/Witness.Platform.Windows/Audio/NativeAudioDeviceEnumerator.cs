using Microsoft.Win32.SafeHandles;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Witness.Core.Audio;

namespace Witness.Platform.Windows.Audio;

public enum NativeAudioDeviceLocation
{
    Unknown = 0,
    BuiltIn = 1,
    External = 2,
}

public static partial class NativeAudioDeviceEnumerator
{
    private const int ErrorCapacity = 512;

    public static IReadOnlyList<AudioInputDevice> GetActiveInputs()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        var error = new byte[ErrorCapacity];
        var status = NativeMethods.Create(out var nativeList, error, (nuint)error.Length);
        using var list = new SafeAudioDeviceListHandle(nativeList);
        if (status != NativeAudioStatus.Ok)
        {
            var terminator = Array.IndexOf(error, (byte)0);
            var message = Encoding.UTF8.GetString(error, 0, terminator < 0 ? error.Length : terminator);
            throw new NativeAudioException(status, string.IsNullOrWhiteSpace(message) ? "Microphone enumeration failed." : message);
        }

        var count = NativeMethods.Count(list);
        if (count > int.MaxValue) throw new InvalidOperationException("Windows returned too many audio devices.");
        var devices = new List<AudioInputDevice>((int)count);
        for (nuint index = 0; index < count; ++index)
        {
            var id = Marshal.PtrToStringUTF8(NativeMethods.Id(list, index));
            var name = Marshal.PtrToStringUTF8(NativeMethods.Name(list, index));
            if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(name)) continue;
            var location = NativeMethods.Location(list, index);
            devices.Add(new AudioInputDevice(
                id,
                name,
                IsActive: true,
                IsBuiltIn: location == NativeAudioDeviceLocation.BuiltIn,
                IsSystemDefault: NativeMethods.IsDefault(list, index) != 0));
        }
        return devices;
    }

    private sealed class SafeAudioDeviceListHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeAudioDeviceListHandle(IntPtr value) : base(ownsHandle: true) => SetHandle(value);
        protected override bool ReleaseHandle()
        {
            NativeMethods.Destroy(handle);
            return true;
        }
    }

    private static partial class NativeMethods
    {
        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_device_list_create")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeAudioStatus Create(out IntPtr result, byte[] error, nuint errorCapacity);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_device_list_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void Destroy(IntPtr list);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_device_list_count")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial nuint Count(SafeAudioDeviceListHandle list);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_device_id")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr Id(SafeAudioDeviceListHandle list, nuint index);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_device_name")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr Name(SafeAudioDeviceListHandle list, nuint index);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_device_is_default")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial int IsDefault(SafeAudioDeviceListHandle list, nuint index);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_device_location_value")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeAudioDeviceLocation Location(SafeAudioDeviceListHandle list, nuint index);
    }
}
