namespace Witness.Core.Audio;

/// <summary>
/// A second, conservative VAD pass for quiet completed audio. It never returns
/// transformed PCM: normalisation answers only whether the bounded original
/// buffer contains speech that live VAD could not hear.
/// </summary>
public static class NormalizedVoiceActivity
{
    public const float MaximumGain = 8F;
    private const float TargetPeak = 0.1F;

    public static NormalizedVoiceActivityResult Analyze(
        ReadOnlySpan<float> samples,
        VoiceActivityConfiguration configuration,
        double sampleRate)
    {
        if (samples.IsEmpty) return NormalizedVoiceActivityResult.None;

        var peak = 0F;
        foreach (var sample in samples)
        {
            if (!float.IsFinite(sample)) continue;
            peak = Math.Max(peak, Math.Abs(sample));
        }

        var validated = configuration.Validated();
        // A signal that cannot reach the speech threshold under the cap stays
        // silence. This prevents a tiny numerical floor from becoming speech.
        if (peak < validated.SpeechThreshold / MaximumGain)
            return NormalizedVoiceActivityResult.None;

        var gain = Math.Min(MaximumGain, TargetPeak / peak);
        var detector = new EnergyVoiceActivityDetector(validated, sampleRate);
        var observation = detector.IngestScaled(samples, gain);
        return observation.SpeechStart is double start
            ? new NormalizedVoiceActivityResult(true, start, gain)
            : new NormalizedVoiceActivityResult(false, null, gain);
    }
}

public sealed record NormalizedVoiceActivityResult(bool HasSpeech, double? SpeechStartSeconds, float AppliedGain)
{
    public static NormalizedVoiceActivityResult None { get; } = new(false, null, 1F);
}
