using Witness.Core.Audio;

namespace Witness.Platform.Windows.Audio;

public interface IAudioPacketSource : IDisposable
{
    BoundedAudioPacketQueue Queue { get; }
    EventWaitHandle PacketAvailable { get; }
    NativeCaptureFormat Start();
    void Stop();
}

/// <summary>Creates a fresh WASAPI segment without extending a phrase lifetime.</summary>
public interface IAudioPacketSourceFactory
{
    IAudioPacketSource Create();
}

public interface IAudioRouteChangeMonitor : IDisposable
{
    event EventHandler? RouteMayHaveChanged;
    void Start();
}

public interface IAudioSampleProcessor
{
    int DecodeToMono(
        ReadOnlySpan<byte> input,
        int frameCount,
        uint channelCount,
        NativeAudioSampleFormat format,
        Span<float> output);

    float[] ResampleTo16Khz(ReadOnlySpan<float> inputMono, uint inputSampleRate);
}

public enum AudioCaptureCompletionKind
{
    Speech,
    NoSpeech,
    InterruptedWithSpeech,
    InterruptedWithoutSpeech,
}

public sealed record AudioCaptureResult(
    AudioCaptureCompletionKind Kind,
    float[] Pcm16KhzMono,
    bool HadDiscontinuity,
    long DroppedPacketCount,
    bool BufferOverflowed,
    uint SourceSampleRate,
    double? SpeechStartSeconds = null,
    int RouteRebindCount = 0);

/// <summary>
/// Drains native packets on a worker, normalizes into a bounded mono buffer,
/// runs VAD at the source rate, then resamples the completed phrase in memory.
/// </summary>
public sealed class AudioCaptureSession(
    IAudioPacketSource source,
    IAudioSampleProcessor processor,
    VoiceActivityConfiguration? voiceActivityConfiguration = null,
    IAudioPacketSourceFactory? rebindSourceFactory = null,
    IAudioRouteChangeMonitor? routeChangeMonitor = null) : IDisposable
{
    private const int MaximumRouteRebindAttempts = 2;
    private readonly VoiceActivityConfiguration vadConfiguration =
        (voiceActivityConfiguration ?? VoiceActivityConfiguration.Default).Validated();
    private readonly object stateGate = new();
    private Task? worker;
    private NativeCaptureFormat format;
    private BoundedPcmBuffer? buffer;
    private EnergyVoiceActivityDetector? vad;
    private Exception? workerFailure;
    private volatile bool stopping;
    private bool interrupted;
    private bool hadDiscontinuity;
    private bool bufferOverflowed;
    private bool disposed;
    private IAudioPacketSource activeSource = source;
    private volatile bool routeRebindRequested;
    private int routeRebindCount;
    private long droppedPacketCount;

    public event EventHandler<VoiceActivityObservation>? ActivityChanged;
    public event EventHandler? AutomaticStopRequested;

    public NativeCaptureFormat Start()
    {
        lock (stateGate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (worker is not null) throw new InvalidOperationException("This capture session has already started.");
            format = activeSource.Start();
            if (format.SampleRate is < 8_000 or > 96_000 || format.ChannelCount is < 1 or > 32 || format.BytesPerFrame == 0)
            {
                activeSource.Stop();
                throw new NativeAudioException(NativeAudioStatus.AudioFormatUnsupported,
                    "The microphone mix format is outside the supported capture bounds.");
            }
            var capacity = checked((int)Math.Ceiling(format.SampleRate * vadConfiguration.MaximumUtteranceDuration));
            buffer = new BoundedPcmBuffer(capacity);
            vad = new EnergyVoiceActivityDetector(vadConfiguration, format.SampleRate);
            if (routeChangeMonitor is not null)
            {
                routeChangeMonitor.RouteMayHaveChanged += RouteMayHaveChanged;
                routeChangeMonitor.Start();
            }
            stopping = false;
            worker = Task.Run(ProcessPackets);
            return format;
        }
    }

    public async Task<AudioCaptureResult> StopAsync()
    {
        Task activeWorker;
        lock (stateGate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            activeWorker = worker ?? throw new InvalidOperationException("This capture session has not started.");
            activeSource.Stop();
            stopping = true;
            activeSource.PacketAvailable.Set();
        }
        await activeWorker.ConfigureAwait(false);
        if (workerFailure is not null) throw new InvalidOperationException("Audio packet processing failed.", workerFailure);

        var captured = buffer ?? throw new InvalidOperationException("The capture buffer was not created.");
        var detector = vad ?? throw new InvalidOperationException("The voice activity detector was not created.");
        var observation = detector.Observation;
        var hasSpeech = observation.SpeechStart is not null;
        if (!hasSpeech && captured.FrameCount > 0)
        {
            // This runs after the packet worker has stopped, off the dispatcher,
            // against the bounded buffer. It intentionally does not modify the
            // PCM later handed to the resampler and local STT engine.
            var completedSamples = captured.MakeSamples();
            NormalizedVoiceActivityResult normalizedActivity;
            try
            {
                normalizedActivity = await Task.Run(() => NormalizedVoiceActivity.Analyze(
                    completedSamples,
                    vadConfiguration,
                    format.SampleRate)).ConfigureAwait(false);
            }
            finally
            {
                Array.Clear(completedSamples);
            }
            hasSpeech = normalizedActivity.HasSpeech;
            if (hasSpeech)
                observation = observation with { SpeechStart = normalizedActivity.SpeechStartSeconds };
        }
        var normalized = hasSpeech
            ? processor.ResampleTo16Khz(captured.Samples, format.SampleRate)
            : [];
        var kind = (interrupted, hasSpeech) switch
        {
            (true, true) => AudioCaptureCompletionKind.InterruptedWithSpeech,
            (true, false) => AudioCaptureCompletionKind.InterruptedWithoutSpeech,
            (false, true) => AudioCaptureCompletionKind.Speech,
            _ => AudioCaptureCompletionKind.NoSpeech,
        };
        return new AudioCaptureResult(
            kind,
            normalized,
            hadDiscontinuity,
            droppedPacketCount + activeSource.Queue.DroppedPacketCount,
            bufferOverflowed,
            format.SampleRate,
            observation.SpeechStart,
            routeRebindCount);
    }

    public void Dispose()
    {
        if (disposed) return;
        activeSource.Stop();
        stopping = true;
        activeSource.PacketAvailable.Set();
        worker?.GetAwaiter().GetResult();
        activeSource.Dispose();
        if (routeChangeMonitor is not null)
        {
            routeChangeMonitor.RouteMayHaveChanged -= RouteMayHaveChanged;
            routeChangeMonitor.Dispose();
        }
        disposed = true;
    }

    /// <summary>
    /// Called by an endpoint-notification adapter. It merely wakes the bounded
    /// worker; device enumeration and reopening never occur in that callback.
    /// </summary>
    public void RequestRouteRebind()
    {
        routeRebindRequested = true;
        activeSource.PacketAvailable.Set();
    }

    private void RouteMayHaveChanged(object? sender, EventArgs args) => RequestRouteRebind();

    private void ProcessPackets()
    {
        try
        {
            while (true)
            {
                var segment = activeSource;
                var maximumFrames = Math.Max(1, segment.Queue.MaximumPacketBytes / checked((int)format.BytesPerFrame));
                var mono = new float[maximumFrames];
                var consumed = false;
                var rebound = false;
                while (segment.Queue.TryConsume((data, frames, flags) =>
                {
                    consumed = true;
                    if ((flags & AudioPacketFlags.Interrupted) != 0)
                    {
                        rebound = TryRebind(segment);
                        if (!rebound)
                        {
                            interrupted = true;
                            AutomaticStopRequested?.Invoke(this, EventArgs.Empty);
                        }
                        return;
                    }
                    if ((flags & AudioPacketFlags.Discontinuity) != 0) hadDiscontinuity = true;
                    if (frames > mono.Length) throw new InvalidOperationException("A native audio packet exceeds the fixed worker buffer.");
                    var written = processor.DecodeToMono(
                        data,
                        frames,
                        format.ChannelCount,
                        format.SampleFormat,
                        mono);
                    var append = buffer!.Append(mono.AsSpan(0, written));
                    if (append.DroppedFrames > 0) bufferOverflowed = true;
                    var observation = vad!.Ingest(mono.AsSpan(0, append.AcceptedFrames));
                    ActivityChanged?.Invoke(this, observation);
                    if (observation.State is VoiceActivityState.EndedBySilence or VoiceActivityState.EndedByMaximumDuration)
                        AutomaticStopRequested?.Invoke(this, EventArgs.Empty);
                })) { }

                if (rebound) continue;
                if (routeRebindRequested)
                {
                    routeRebindRequested = false;
                    if (TryRebind(segment)) continue;
                }
                if (stopping && !consumed) break;
                segment.PacketAvailable.WaitOne(100);
            }
        }
        catch (Exception error)
        {
            workerFailure = error;
        }
    }

    private bool TryRebind(IAudioPacketSource previous)
    {
        if (rebindSourceFactory is null || routeRebindCount >= MaximumRouteRebindAttempts || stopping)
            return false;

        IAudioPacketSource? replacement = null;
        try
        {
            previous.Stop();
            replacement = rebindSourceFactory.Create();
            var replacementFormat = replacement.Start();
            // Different sample formats/channels are decoded per packet, but a
            // sample-rate switch needs a segment-aware resampler and must not
            // quietly corrupt the phrase.
            if (replacementFormat.SampleRate != format.SampleRate)
                throw new NativeAudioException(NativeAudioStatus.AudioFormatUnsupported,
                    "The replacement microphone changed sample rate during the phrase.");
            activeSource = replacement;
            format = replacementFormat;
            replacement = null;
            droppedPacketCount += previous.Queue.DroppedPacketCount;
            previous.Dispose();
            hadDiscontinuity = true;
            routeRebindCount++;
            return true;
        }
        catch
        {
            replacement?.Dispose();
            return false;
        }
    }
}
