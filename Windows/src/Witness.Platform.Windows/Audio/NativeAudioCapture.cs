using Microsoft.Win32.SafeHandles;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace Witness.Platform.Windows.Audio;

public enum NativeAudioSampleFormat : uint
{
    Pcm16LittleEndian = 1,
    Pcm24LittleEndian = 2,
    Pcm32LittleEndian = 3,
    Float32LittleEndian = 4,
    Pcm24In32LittleEndian = 5,
}

[StructLayout(LayoutKind.Sequential)]
public readonly record struct NativeCaptureFormat(
    uint SampleRate,
    uint ChannelCount,
    uint BytesPerFrame,
    NativeAudioSampleFormat SampleFormat);

public enum NativeAudioStatus
{
    Ok = 0,
    InvalidArgument = 1,
    ModelLoadFailed = 2,
    TranscriptionFailed = 3,
    OutOfMemory = 4,
    InternalError = 5,
    AudioAccessDenied = 6,
    AudioDeviceUnavailable = 7,
    AudioFormatUnsupported = 8,
}

public sealed class NativeAudioException(NativeAudioStatus status, string message) : Exception(message)
{
    public NativeAudioStatus Status { get; } = status;
}

public sealed partial class NativeAudioCapture : IDisposable
{
    private const int ErrorCapacity = 512;
    private readonly NativeMethods.PacketCallback callback;
    private readonly SafeAudioCaptureHandle handle;
    private bool started;

    public NativeAudioCapture(string? endpointId, int packetCapacity = 64, int maximumPacketBytes = 65_536)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        Queue = new BoundedAudioPacketQueue(packetCapacity, maximumPacketBytes);
        callback = ReceivePacket;
        var error = new byte[ErrorCapacity];
        var status = NativeMethods.Create(endpointId, callback, IntPtr.Zero, out var nativeHandle, error, (nuint)error.Length);
        handle = new SafeAudioCaptureHandle(nativeHandle);
        ThrowIfFailed(status, error);
    }

    public BoundedAudioPacketQueue Queue { get; }
    public EventWaitHandle PacketAvailable { get; } = new AutoResetEvent(false);

    public NativeCaptureFormat Start()
    {
        ObjectDisposedException.ThrowIf(handle.IsClosed, this);
        var error = new byte[ErrorCapacity];
        var status = NativeMethods.Start(handle, out var format, error, (nuint)error.Length);
        ThrowIfFailed(status, error);
        started = true;
        return format;
    }

    public void Stop()
    {
        if (!started || handle.IsClosed) return;
        NativeMethods.Stop(handle);
        started = false;
    }

    public void Dispose()
    {
        Stop();
        handle.Dispose();
        PacketAvailable.Dispose();
    }

    private void ReceivePacket(IntPtr userContext, IntPtr data, nuint sizeBytes, nuint frameCount, uint flags)
    {
        try
        {
            if (sizeBytes > int.MaxValue || frameCount > int.MaxValue ||
                !Queue.TryWrite(data, (int)sizeBytes, (int)frameCount, (AudioPacketFlags)flags)) return;
            PacketAvailable.Set();
        }
        catch
        {
            // Exceptions must never cross the native callback boundary. Invalid
            // or oversized packets are represented by the queue's drop count.
        }
    }

    private static void ThrowIfFailed(NativeAudioStatus status, byte[] error)
    {
        if (status == NativeAudioStatus.Ok) return;
        var terminator = Array.IndexOf(error, (byte)0);
        var message = Encoding.UTF8.GetString(error, 0, terminator < 0 ? error.Length : terminator);
        throw new NativeAudioException(status, string.IsNullOrWhiteSpace(message) ? "Native audio capture failed." : message);
    }

    private sealed class SafeAudioCaptureHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeAudioCaptureHandle(IntPtr value) : base(ownsHandle: true) => SetHandle(value);

        protected override bool ReleaseHandle()
        {
            NativeMethods.Destroy(handle);
            return true;
        }
    }

    private static partial class NativeMethods
    {
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate void PacketCallback(IntPtr userContext, IntPtr data, nuint sizeBytes, nuint frameCount, uint flags);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_capture_create", StringMarshalling = StringMarshalling.Utf8)]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeAudioStatus Create(
            string? endpointId,
            PacketCallback callback,
            IntPtr userContext,
            out IntPtr result,
            byte[] error,
            nuint errorCapacity);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_capture_start")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeAudioStatus Start(
            SafeAudioCaptureHandle capture,
            out NativeCaptureFormat format,
            byte[] error,
            nuint errorCapacity);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_capture_stop")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void Stop(SafeAudioCaptureHandle capture);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_capture_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void Destroy(IntPtr capture);
    }
}
