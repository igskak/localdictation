namespace Witness.Core.Audio;

public sealed record VoiceActivityConfiguration(
    double WindowDuration,
    float SpeechThreshold,
    float SilenceThreshold,
    int SpeechActivationWindows,
    double TrailingSilenceDuration,
    double MaximumUtteranceDuration)
{
    public static VoiceActivityConfiguration Default { get; } = new(0.02, 0.02F, 0.012F, 3, 1.0, 300);

    public VoiceActivityConfiguration Validated()
    {
        var speech = Math.Clamp(SpeechThreshold, 0.0005F, 0.5F);
        return this with
        {
            WindowDuration = Math.Clamp(WindowDuration, 0.005, 0.1),
            SpeechThreshold = speech,
            SilenceThreshold = Math.Clamp(SilenceThreshold, 0.0001F, speech),
            SpeechActivationWindows = Math.Max(SpeechActivationWindows, 1),
            TrailingSilenceDuration = Math.Clamp(TrailingSilenceDuration, 0.1, 10),
            MaximumUtteranceDuration = Math.Clamp(MaximumUtteranceDuration, 1, 600),
        };
    }
}

public enum VoiceActivityState
{
    Idle,
    Speaking,
    TrailingSilence,
    EndedBySilence,
    EndedByMaximumDuration,
}

public sealed record VoiceActivityObservation(
    VoiceActivityState State,
    double? SpeechStart,
    double TrailingSilence,
    double Elapsed,
    float LastWindowRms);

public sealed class EnergyVoiceActivityDetector
{
    private readonly int _windowFrames;
    private readonly int _activationFrames;
    private readonly int _trailingSilenceFrames;
    private readonly int _maximumFrames;
    private float _squaredSum;
    private int _windowFill;
    private int _consecutiveSpeechWindows;
    private int _elapsedFrames;
    private int _silenceFrames;
    private int? _speechStartFrame;
    private VoiceActivityState _state;
    private float _lastWindowRms;

    public EnergyVoiceActivityDetector(VoiceActivityConfiguration? configuration = null, double sampleRate = 16_000)
    {
        if (sampleRate <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sampleRate));
        }
        Configuration = (configuration ?? VoiceActivityConfiguration.Default).Validated();
        SampleRate = sampleRate;
        _windowFrames = Math.Max((int)Math.Round(Configuration.WindowDuration * sampleRate), 1);
        _activationFrames = _windowFrames * Configuration.SpeechActivationWindows;
        _trailingSilenceFrames = Math.Max((int)Math.Round(Configuration.TrailingSilenceDuration * sampleRate), _windowFrames);
        _maximumFrames = Math.Max((int)Math.Round(Configuration.MaximumUtteranceDuration * sampleRate), _windowFrames);
    }

    public VoiceActivityConfiguration Configuration { get; }
    public double SampleRate { get; }
    public VoiceActivityObservation Observation => new(
        _state,
        _speechStartFrame is int start ? start / SampleRate : null,
        _silenceFrames / SampleRate,
        _elapsedFrames / SampleRate,
        _lastWindowRms);

    public void Reset()
    {
        _squaredSum = 0;
        _windowFill = 0;
        _consecutiveSpeechWindows = 0;
        _elapsedFrames = 0;
        _silenceFrames = 0;
        _speechStartFrame = null;
        _state = VoiceActivityState.Idle;
        _lastWindowRms = 0;
    }

    public VoiceActivityObservation Ingest(ReadOnlySpan<float> frames)
        => Ingest(frames, 1F);

    /// <summary>
    /// Evaluates a bounded audio buffer at a gain used solely for VAD. The
    /// caller retains the original samples for transcription.
    /// </summary>
    public VoiceActivityObservation IngestScaled(ReadOnlySpan<float> frames, float gain)
        => Ingest(frames, gain);

    private VoiceActivityObservation Ingest(ReadOnlySpan<float> frames, float gain)
    {
        if (!float.IsFinite(gain) || gain <= 0) throw new ArgumentOutOfRangeException(nameof(gain));
        var index = 0;
        while (index < frames.Length)
        {
            var take = Math.Min(_windowFrames - _windowFill, frames.Length - index);
            var sum = _squaredSum;
            for (var offset = 0; offset < take; offset++)
            {
                var sample = Math.Clamp(frames[index + offset] * gain, -1F, 1F);
                sum += sample * sample;
            }
            _squaredSum = sum;
            _windowFill += take;
            index += take;
            _elapsedFrames += take;

            if (_windowFill == _windowFrames)
            {
                var meanSquare = _squaredSum / _windowFrames;
                _lastWindowRms = meanSquare > 0 ? MathF.Sqrt(meanSquare) : 0;
                _squaredSum = 0;
                _windowFill = 0;
                Advance(_lastWindowRms);
            }

            if (_elapsedFrames >= _maximumFrames)
            {
                _state = VoiceActivityState.EndedByMaximumDuration;
                return Observation;
            }
        }
        return Observation;
    }

    private void Advance(float rms)
    {
        if (_state is VoiceActivityState.EndedBySilence or VoiceActivityState.EndedByMaximumDuration)
        {
            return;
        }

        switch (_state)
        {
            case VoiceActivityState.Idle:
                if (rms >= Configuration.SpeechThreshold)
                {
                    _consecutiveSpeechWindows++;
                    if (_consecutiveSpeechWindows >= Configuration.SpeechActivationWindows)
                    {
                        _state = VoiceActivityState.Speaking;
                        _speechStartFrame = Math.Max(_elapsedFrames - _activationFrames, 0);
                        _silenceFrames = 0;
                    }
                }
                else
                {
                    _consecutiveSpeechWindows = 0;
                }
                break;
            case VoiceActivityState.Speaking:
                if (rms < Configuration.SilenceThreshold)
                {
                    _silenceFrames += _windowFrames;
                    _state = _silenceFrames >= _trailingSilenceFrames
                        ? VoiceActivityState.EndedBySilence
                        : VoiceActivityState.TrailingSilence;
                }
                else
                {
                    _silenceFrames = 0;
                }
                break;
            case VoiceActivityState.TrailingSilence:
                if (rms >= Configuration.SpeechThreshold)
                {
                    _silenceFrames = 0;
                    _state = VoiceActivityState.Speaking;
                }
                else if (rms < Configuration.SilenceThreshold)
                {
                    _silenceFrames += _windowFrames;
                    if (_silenceFrames >= _trailingSilenceFrames)
                    {
                        _state = VoiceActivityState.EndedBySilence;
                    }
                }
                break;
        }
    }
}
