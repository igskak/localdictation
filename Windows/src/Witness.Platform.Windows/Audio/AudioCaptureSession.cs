using Witness.Core.Audio;

namespace Witness.Platform.Windows.Audio;

public interface IAudioPacketSource : IDisposable
{
    BoundedAudioPacketQueue Queue { get; }
    EventWaitHandle PacketAvailable { get; }
    NativeCaptureFormat Start();
    void Stop();
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
    double? SpeechStartSeconds = null);

/// <summary>
/// Drains native packets on a worker, normalizes into a bounded mono buffer,
/// runs VAD at the source rate, then resamples the completed phrase in memory.
/// </summary>
public sealed class AudioCaptureSession(
    IAudioPacketSource source,
    IAudioSampleProcessor processor,
    VoiceActivityConfiguration? voiceActivityConfiguration = null) : IDisposable
{
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

    public event EventHandler<VoiceActivityObservation>? ActivityChanged;
    public event EventHandler? AutomaticStopRequested;

    public NativeCaptureFormat Start()
    {
        lock (stateGate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (worker is not null) throw new InvalidOperationException("This capture session has already started.");
            format = source.Start();
            if (format.SampleRate is < 8_000 or > 96_000 || format.ChannelCount is < 1 or > 32 || format.BytesPerFrame == 0)
            {
                source.Stop();
                throw new NativeAudioException(NativeAudioStatus.AudioFormatUnsupported,
                    "The microphone mix format is outside the supported capture bounds.");
            }
            var capacity = checked((int)Math.Ceiling(format.SampleRate * vadConfiguration.MaximumUtteranceDuration));
            buffer = new BoundedPcmBuffer(capacity);
            vad = new EnergyVoiceActivityDetector(vadConfiguration, format.SampleRate);
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
            source.Stop();
            stopping = true;
            source.PacketAvailable.Set();
        }
        await activeWorker.ConfigureAwait(false);
        if (workerFailure is not null) throw new InvalidOperationException("Audio packet processing failed.", workerFailure);

        var captured = buffer ?? throw new InvalidOperationException("The capture buffer was not created.");
        var detector = vad ?? throw new InvalidOperationException("The voice activity detector was not created.");
        var observation = detector.Observation;
        var hasSpeech = observation.SpeechStart is not null;
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
            source.Queue.DroppedPacketCount,
            bufferOverflowed,
            format.SampleRate,
            observation.SpeechStart);
    }

    public void Dispose()
    {
        if (disposed) return;
        source.Stop();
        stopping = true;
        source.PacketAvailable.Set();
        worker?.GetAwaiter().GetResult();
        source.Dispose();
        disposed = true;
    }

    private void ProcessPackets()
    {
        try
        {
            var maximumFrames = Math.Max(1, source.Queue.MaximumPacketBytes / checked((int)format.BytesPerFrame));
            var mono = new float[maximumFrames];
            while (true)
            {
                var consumed = false;
                while (source.Queue.TryConsume((data, frames, flags) =>
                {
                    consumed = true;
                    if ((flags & AudioPacketFlags.Interrupted) != 0)
                    {
                        interrupted = true;
                        AutomaticStopRequested?.Invoke(this, EventArgs.Empty);
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

                if (stopping && !consumed) break;
                source.PacketAvailable.WaitOne(100);
            }
        }
        catch (Exception error)
        {
            workerFailure = error;
        }
    }
}
