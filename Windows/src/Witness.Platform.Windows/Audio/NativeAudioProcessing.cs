using Microsoft.Win32.SafeHandles;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace Witness.Platform.Windows.Audio;

public static partial class NativeAudioProcessing
{
    private const int ErrorCapacity = 512;

    public static unsafe int DecodeToMono(
        ReadOnlySpan<byte> input,
        int frameCount,
        uint channelCount,
        NativeAudioSampleFormat format,
        Span<float> output)
    {
        if (frameCount < 0 || output.Length < frameCount) throw new ArgumentOutOfRangeException(nameof(frameCount));
        fixed (byte* inputPointer = input)
        fixed (float* outputPointer = output)
        {
            var status = NativeMethods.DecodeToMono(
                inputPointer,
                (nuint)input.Length,
                (nuint)frameCount,
                channelCount,
                format,
                outputPointer,
                (nuint)output.Length,
                out var written);
            if (status != NativeAudioStatus.Ok)
                throw new NativeAudioException(status, "Native audio sample normalization failed.");
            return checked((int)written);
        }
    }

    public static unsafe float[] ResampleTo16Khz(ReadOnlySpan<float> inputMono, uint inputSampleRate)
    {
        if (inputMono.IsEmpty) throw new ArgumentException("Audio input cannot be empty.", nameof(inputMono));
        var error = new byte[ErrorCapacity];
        fixed (float* inputPointer = inputMono)
        {
            var status = NativeMethods.ResampleTo16Khz(
                inputPointer,
                (nuint)inputMono.Length,
                inputSampleRate,
                out var nativeBuffer,
                error,
                (nuint)error.Length);
            using var buffer = new SafeAudioBufferHandle(nativeBuffer);
            ThrowIfFailed(status, error);
            var count = NativeMethods.BufferSampleCount(buffer);
            if (count > int.MaxValue) throw new InvalidOperationException("The resampled recording is too large.");
            var data = NativeMethods.BufferData(buffer);
            if (data == IntPtr.Zero || count == 0)
                throw new InvalidOperationException("The audio resampler returned an empty recording.");
            return new ReadOnlySpan<float>(data.ToPointer(), (int)count).ToArray();
        }
    }

    private static void ThrowIfFailed(NativeAudioStatus status, byte[] error)
    {
        if (status == NativeAudioStatus.Ok) return;
        var terminator = Array.IndexOf(error, (byte)0);
        var message = Encoding.UTF8.GetString(error, 0, terminator < 0 ? error.Length : terminator);
        throw new NativeAudioException(status, string.IsNullOrWhiteSpace(message) ? "Native audio processing failed." : message);
    }

    private sealed class SafeAudioBufferHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeAudioBufferHandle(IntPtr value) : base(ownsHandle: true) => SetHandle(value);

        protected override bool ReleaseHandle()
        {
            NativeMethods.BufferDestroy(handle);
            return true;
        }
    }

    private static partial class NativeMethods
    {
        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_decode_to_mono")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static unsafe partial NativeAudioStatus DecodeToMono(
            byte* input,
            nuint inputSizeBytes,
            nuint frameCount,
            uint channelCount,
            NativeAudioSampleFormat format,
            float* output,
            nuint outputCapacityFrames,
            out nuint outputFrameCount);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_resample_to_16khz")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static unsafe partial NativeAudioStatus ResampleTo16Khz(
            float* inputMono,
            nuint inputSampleCount,
            uint inputSampleRate,
            out IntPtr result,
            byte[] error,
            nuint errorCapacity);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_buffer_data")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr BufferData(SafeAudioBufferHandle buffer);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_buffer_sample_count")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial nuint BufferSampleCount(SafeAudioBufferHandle buffer);

        [LibraryImport("Witness.Native", EntryPoint = "witness_audio_buffer_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void BufferDestroy(IntPtr buffer);
    }
}
