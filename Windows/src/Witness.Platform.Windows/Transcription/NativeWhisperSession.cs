using Microsoft.Win32.SafeHandles;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Witness.Core.Languages;
using Witness.Core.Transcription;

namespace Witness.Platform.Windows.Transcription;

public enum NativeTranscriptionStatus
{
    Ok = 0,
    InvalidArgument = 1,
    ModelLoadFailed = 2,
    TranscriptionFailed = 3,
    OutOfMemory = 4,
    InternalError = 5,
    Cancelled = 9,
    BackendUnavailable = 10,
    LanguageDetectionFailed = 11,
}

public sealed class NativeTranscriptionException(
    NativeTranscriptionStatus status,
    string message) : Exception(message)
{
    public NativeTranscriptionStatus Status { get; } = status;
}

[Flags]
public enum NativeBackendCapabilities : uint
{
    Cpu = 1,
    GpuDevice = 2,
    GpuInitialized = 4,
    VulkanCompiled = 8,
}

public sealed partial class NativeWhisperSession : ITranscriptionBackend, ILanguageProbabilityProvider
{
    private const uint RequiredAbiVersion = 3;
    private const int ErrorCapacity = 512;
    private const int MaximumSamples = 16_000 * 600;
    private readonly SafeWhisperContextHandle context;
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private readonly bool useGpu;
    private bool disposed;

    private NativeWhisperSession(SafeWhisperContextHandle context, bool useGpu)
    {
        this.context = context;
        this.useGpu = useGpu;
    }

    public TranscriptionBackendKind Kind => useGpu
        ? TranscriptionBackendKind.Vulkan
        : TranscriptionBackendKind.Cpu;

    public static NativeBackendCapabilities ProbeBackendCapabilities()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }
        return (NativeBackendCapabilities)NativeMethods.BackendCapabilities();
    }

    public static async Task<NativeWhisperSession> LoadAsync(
        string modelPath,
        bool useGpu,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(modelPath);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }

        cancellationToken.ThrowIfCancellationRequested();
        NativeWhisperSession session;
        try
        {
            session = await Task.Run(() => LoadCore(modelPath, useGpu)).ConfigureAwait(false);
        }
        catch (NativeTranscriptionException error) when (useGpu && CanRetryGpuFailureOnCpu(error.Status))
        {
            throw new TranscriptionBackendException(
                TranscriptionBackendKind.Vulkan,
                error.Status == NativeTranscriptionStatus.BackendUnavailable
                    ? TranscriptionBackendFailureKind.Unavailable
                    : TranscriptionBackendFailureKind.Initialization,
                canRetryOnCpu: true,
                "The accelerated speech backend could not be initialized.",
                error);
        }
        if (cancellationToken.IsCancellationRequested)
        {
            await session.DisposeAsync().ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
        }
        return session;
    }

    public Task<TranscriptionOutput> TranscribeAsync(
        TranscriptionRequest request,
        CancellationToken cancellationToken) => TranscribeAsync(
            request.Pcm16KhzMono,
            request.LanguageCode,
            request.ThreadCount,
            cancellationToken);

    public async Task<IReadOnlyDictionary<string, float>> DetectProbabilitiesAsync(
        ReadOnlyMemory<float> completedPcm16KhzMono,
        int threadCount,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (completedPcm16KhzMono.IsEmpty || completedPcm16KhzMono.Length > MaximumSamples)
        {
            throw new ArgumentOutOfRangeException(nameof(completedPcm16KhzMono));
        }
        if (threadCount < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(threadCount));
        }

        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            try
            {
                return await Task.Run(
                        () => DetectProbabilitiesCore(completedPcm16KhzMono, threadCount, cancellationToken),
                        CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch (NativeTranscriptionException error) when (
                Kind == TranscriptionBackendKind.Vulkan
                && CanRetryGpuFailureOnCpu(error.Status))
            {
                throw new TranscriptionBackendException(
                    Kind,
                    TranscriptionBackendFailureKind.Execution,
                    canRetryOnCpu: true,
                    "The accelerated speech backend failed during language detection.",
                    error);
            }
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task<TranscriptionOutput> TranscribeAsync(
        ReadOnlyMemory<float> pcm16KhzMono,
        string? languageCode,
        int threadCount,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (pcm16KhzMono.IsEmpty || pcm16KhzMono.Length > MaximumSamples)
        {
            throw new ArgumentOutOfRangeException(nameof(pcm16KhzMono));
        }
        if (threadCount < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(threadCount));
        }

        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            try
            {
                return await Task.Run(
                        () => TranscribeCore(pcm16KhzMono, languageCode, threadCount, cancellationToken),
                        CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch (NativeTranscriptionException error) when (
                Kind == TranscriptionBackendKind.Vulkan
                && CanRetryGpuFailureOnCpu(error.Status))
            {
                throw new TranscriptionBackendException(
                    Kind,
                    TranscriptionBackendFailureKind.Execution,
                    canRetryOnCpu: true,
                    "The accelerated speech backend failed.",
                    error);
            }
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            context.Dispose();
        }
        finally
        {
            operationGate.Release();
            operationGate.Dispose();
        }
    }

    private static NativeWhisperSession LoadCore(string modelPath, bool useGpu)
    {
        if (NativeMethods.AbiVersion() != RequiredAbiVersion)
        {
            throw new NativeTranscriptionException(
                NativeTranscriptionStatus.InternalError,
                "The native speech engine ABI does not match this application build.");
        }

        var error = new byte[ErrorCapacity];
        var status = NativeMethods.ContextCreate(
            modelPath,
            useGpu ? 1 : 0,
            out var nativeContext,
            error,
            (nuint)error.Length);
        var context = new SafeWhisperContextHandle(nativeContext);
        if (status != NativeTranscriptionStatus.Ok)
        {
            context.Dispose();
            ThrowNative(status, error);
        }
        if (useGpu && NativeMethods.ContextUsesGpu(context) == 0)
        {
            context.Dispose();
            throw new NativeTranscriptionException(
                NativeTranscriptionStatus.BackendUnavailable,
                "The native speech engine did not activate the requested GPU backend.");
        }
        return new NativeWhisperSession(context, useGpu);
    }

    private static bool CanRetryGpuFailureOnCpu(NativeTranscriptionStatus status) => status is
        NativeTranscriptionStatus.ModelLoadFailed
        or NativeTranscriptionStatus.TranscriptionFailed
        or NativeTranscriptionStatus.InternalError
        or NativeTranscriptionStatus.BackendUnavailable
        or NativeTranscriptionStatus.LanguageDetectionFailed;

    private unsafe TranscriptionOutput TranscribeCore(
        ReadOnlyMemory<float> pcm,
        string? languageCode,
        int threadCount,
        CancellationToken cancellationToken)
    {
        var cancellationStatus = NativeMethods.CancellationCreate(out var nativeCancellation);
        using var cancellation = new SafeCancellationHandle(nativeCancellation);
        if (cancellationStatus != NativeTranscriptionStatus.Ok)
        {
            ThrowNative(cancellationStatus, []);
        }
        using var registration = cancellationToken.Register(
            static state => ((SafeCancellationHandle)state!).Cancel(),
            cancellation);
        var error = new byte[ErrorCapacity];
        fixed (float* samples = pcm.Span)
        {
            var status = NativeMethods.TranscribeCancelable(
                context,
                samples,
                (nuint)pcm.Length,
                string.IsNullOrWhiteSpace(languageCode) ? null : languageCode,
                threadCount,
                cancellation,
                out var nativeTranscript,
                error,
                (nuint)error.Length);
            using var transcript = new SafeTranscriptHandle(nativeTranscript);
            if (status == NativeTranscriptionStatus.Cancelled)
            {
                throw new OperationCanceledException(cancellationToken);
            }
            if (status != NativeTranscriptionStatus.Ok)
            {
                ThrowNative(status, error);
            }
            return ReadTranscript(transcript);
        }
    }

    private unsafe IReadOnlyDictionary<string, float> DetectProbabilitiesCore(
        ReadOnlyMemory<float> pcm,
        int threadCount,
        CancellationToken cancellationToken)
    {
        var cancellationStatus = NativeMethods.CancellationCreate(out var nativeCancellation);
        using var cancellation = new SafeCancellationHandle(nativeCancellation);
        if (cancellationStatus != NativeTranscriptionStatus.Ok)
        {
            ThrowNative(cancellationStatus, []);
        }
        using var registration = cancellationToken.Register(
            static state => ((SafeCancellationHandle)state!).Cancel(),
            cancellation);
        var error = new byte[ErrorCapacity];
        fixed (float* samples = pcm.Span)
        {
            var status = NativeMethods.DetectLanguages(
                context,
                samples,
                (nuint)pcm.Length,
                threadCount,
                cancellation,
                out var nativeScores,
                error,
                (nuint)error.Length);
            using var scores = new SafeLanguageScoresHandle(nativeScores);
            if (status == NativeTranscriptionStatus.Cancelled)
            {
                throw new OperationCanceledException(cancellationToken);
            }
            if (status != NativeTranscriptionStatus.Ok)
            {
                ThrowNative(status, error);
            }

            var count = CheckedCount(NativeMethods.LanguageScoresCount(scores));
            var probabilities = new Dictionary<string, float>(count, StringComparer.Ordinal);
            for (var index = 0; index < count; index++)
            {
                var nativeIndex = (nuint)index;
                var code = Marshal.PtrToStringUTF8(NativeMethods.LanguageScoreCode(scores, nativeIndex));
                var probability = NativeMethods.LanguageScoreProbability(scores, nativeIndex);
                if (!string.IsNullOrWhiteSpace(code) && float.IsFinite(probability))
                {
                    probabilities[code] = Math.Clamp(probability, 0, 1);
                }
            }
            if (probabilities.Count == 0)
            {
                throw new NativeTranscriptionException(
                    NativeTranscriptionStatus.LanguageDetectionFailed,
                    "The speech engine returned no valid language scores.");
            }
            return probabilities;
        }
    }

    private TranscriptionOutput ReadTranscript(SafeTranscriptHandle transcript)
    {
        var language = Marshal.PtrToStringUTF8(NativeMethods.TranscriptLanguage(transcript)) ?? string.Empty;
        var segmentCount = CheckedCount(NativeMethods.SegmentCount(transcript));
        var segments = new List<TranscriptionSegment>(segmentCount);
        for (var segmentIndex = 0; segmentIndex < segmentCount; segmentIndex++)
        {
            var nativeSegmentIndex = (nuint)segmentIndex;
            var text = Marshal.PtrToStringUTF8(NativeMethods.SegmentText(transcript, nativeSegmentIndex))
                ?? string.Empty;
            var startMs = NativeMethods.SegmentStartMs(transcript, nativeSegmentIndex);
            var endMs = NativeMethods.SegmentEndMs(transcript, nativeSegmentIndex);
            if (startMs < 0 || endMs < startMs)
            {
                throw new NativeTranscriptionException(
                    NativeTranscriptionStatus.TranscriptionFailed,
                    "The speech engine returned invalid segment timing.");
            }

            var tokenCount = CheckedCount(NativeMethods.TokenCount(transcript, nativeSegmentIndex));
            var tokens = new List<TranscriptionToken>(tokenCount);
            for (var tokenIndex = 0; tokenIndex < tokenCount; tokenIndex++)
            {
                var nativeTokenIndex = (nuint)tokenIndex;
                var tokenText = Marshal.PtrToStringUTF8(NativeMethods.TokenText(
                    transcript,
                    nativeSegmentIndex,
                    nativeTokenIndex)) ?? string.Empty;
                var probability = NativeMethods.TokenProbability(
                    transcript,
                    nativeSegmentIndex,
                    nativeTokenIndex);
                var tokenStart = NativeMethods.TokenStartMs(transcript, nativeSegmentIndex, nativeTokenIndex);
                var tokenEnd = NativeMethods.TokenEndMs(transcript, nativeSegmentIndex, nativeTokenIndex);
                tokens.Add(new TranscriptionToken(
                    tokenText,
                    float.IsFinite(probability) ? Math.Clamp(probability, 0, 1) : 0,
                    tokenStart < 0 ? null : TimeSpan.FromMilliseconds(tokenStart),
                    tokenEnd < 0 ? null : TimeSpan.FromMilliseconds(tokenEnd)));
            }

            segments.Add(new TranscriptionSegment(
                text,
                TimeSpan.FromMilliseconds(startMs),
                TimeSpan.FromMilliseconds(endMs),
                tokens));
        }

        return new TranscriptionOutput(
            language,
            TranscriptionWordMapper.Map(segments),
            Kind);
    }

    private static int CheckedCount(nuint value) => value > int.MaxValue
        ? throw new NativeTranscriptionException(
            NativeTranscriptionStatus.TranscriptionFailed,
            "The speech engine returned too many result items.")
        : (int)value;

    private static void ThrowNative(NativeTranscriptionStatus status, byte[] error)
    {
        var terminator = Array.IndexOf(error, (byte)0);
        var message = error.Length == 0
            ? string.Empty
            : Encoding.UTF8.GetString(error, 0, terminator < 0 ? error.Length : terminator);
        throw new NativeTranscriptionException(
            status,
            string.IsNullOrWhiteSpace(message) ? "The local speech engine failed." : message);
    }

    private sealed class SafeWhisperContextHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeWhisperContextHandle(IntPtr value) : base(ownsHandle: true) => SetHandle(value);
        protected override bool ReleaseHandle()
        {
            NativeMethods.ContextDestroy(handle);
            return true;
        }
    }

    private sealed class SafeTranscriptHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeTranscriptHandle(IntPtr value) : base(ownsHandle: true) => SetHandle(value);
        protected override bool ReleaseHandle()
        {
            NativeMethods.TranscriptDestroy(handle);
            return true;
        }
    }

    private sealed class SafeLanguageScoresHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeLanguageScoresHandle(IntPtr value) : base(ownsHandle: true) => SetHandle(value);
        protected override bool ReleaseHandle()
        {
            NativeMethods.LanguageScoresDestroy(handle);
            return true;
        }
    }

    private sealed class SafeCancellationHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal SafeCancellationHandle(IntPtr value) : base(ownsHandle: true) => SetHandle(value);
        internal void Cancel()
        {
            if (!IsClosed && !IsInvalid)
            {
                NativeMethods.CancellationCancel(this);
            }
        }
        protected override bool ReleaseHandle()
        {
            NativeMethods.CancellationDestroy(handle);
            return true;
        }
    }

    private static partial class NativeMethods
    {
        [LibraryImport("Witness.Native", EntryPoint = "witness_native_abi_version")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial uint AbiVersion();

        [LibraryImport("Witness.Native", EntryPoint = "witness_backend_capabilities")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial uint BackendCapabilities();

        [LibraryImport("Witness.Native", EntryPoint = "witness_context_create", StringMarshalling = StringMarshalling.Utf8)]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeTranscriptionStatus ContextCreate(
            string modelPath,
            int useGpu,
            out IntPtr result,
            byte[] error,
            nuint errorCapacity);

        [LibraryImport("Witness.Native", EntryPoint = "witness_context_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void ContextDestroy(IntPtr context);

        [LibraryImport("Witness.Native", EntryPoint = "witness_context_uses_gpu")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial int ContextUsesGpu(SafeWhisperContextHandle context);

        [LibraryImport("Witness.Native", EntryPoint = "witness_cancellation_create")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial NativeTranscriptionStatus CancellationCreate(out IntPtr result);

        [LibraryImport("Witness.Native", EntryPoint = "witness_cancellation_cancel")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void CancellationCancel(SafeCancellationHandle cancellation);

        [LibraryImport("Witness.Native", EntryPoint = "witness_cancellation_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void CancellationDestroy(IntPtr cancellation);

        [LibraryImport("Witness.Native", EntryPoint = "witness_detect_languages")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static unsafe partial NativeTranscriptionStatus DetectLanguages(
            SafeWhisperContextHandle context,
            float* pcm16KhzMono,
            nuint sampleCount,
            int threadCount,
            SafeCancellationHandle cancellation,
            out IntPtr result,
            byte[] error,
            nuint errorCapacity);

        [LibraryImport("Witness.Native", EntryPoint = "witness_language_scores_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void LanguageScoresDestroy(IntPtr scores);

        [LibraryImport("Witness.Native", EntryPoint = "witness_language_scores_count")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial nuint LanguageScoresCount(SafeLanguageScoresHandle scores);

        [LibraryImport("Witness.Native", EntryPoint = "witness_language_score_code")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr LanguageScoreCode(SafeLanguageScoresHandle scores, nuint index);

        [LibraryImport("Witness.Native", EntryPoint = "witness_language_score_probability")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial float LanguageScoreProbability(SafeLanguageScoresHandle scores, nuint index);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcribe_cancelable", StringMarshalling = StringMarshalling.Utf8)]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static unsafe partial NativeTranscriptionStatus TranscribeCancelable(
            SafeWhisperContextHandle context,
            float* pcm16KhzMono,
            nuint sampleCount,
            string? languageCode,
            int threadCount,
            SafeCancellationHandle cancellation,
            out IntPtr result,
            byte[] error,
            nuint errorCapacity);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_destroy")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial void TranscriptDestroy(IntPtr transcript);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_language")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr TranscriptLanguage(SafeTranscriptHandle transcript);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_segment_count")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial nuint SegmentCount(SafeTranscriptHandle transcript);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_segment_text")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr SegmentText(SafeTranscriptHandle transcript, nuint segmentIndex);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_segment_start_ms")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial long SegmentStartMs(SafeTranscriptHandle transcript, nuint segmentIndex);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_segment_end_ms")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial long SegmentEndMs(SafeTranscriptHandle transcript, nuint segmentIndex);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_segment_token_count")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial nuint TokenCount(SafeTranscriptHandle transcript, nuint segmentIndex);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_token_text")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial IntPtr TokenText(
            SafeTranscriptHandle transcript,
            nuint segmentIndex,
            nuint tokenIndex);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_token_probability")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial float TokenProbability(
            SafeTranscriptHandle transcript,
            nuint segmentIndex,
            nuint tokenIndex);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_token_start_ms")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial long TokenStartMs(
            SafeTranscriptHandle transcript,
            nuint segmentIndex,
            nuint tokenIndex);

        [LibraryImport("Witness.Native", EntryPoint = "witness_transcript_token_end_ms")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        internal static partial long TokenEndMs(
            SafeTranscriptHandle transcript,
            nuint segmentIndex,
            nuint tokenIndex);
    }
}
