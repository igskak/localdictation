namespace Witness.Core.Languages;

public interface ILanguageProbabilityProvider
{
    Task<IReadOnlyDictionary<string, float>> DetectProbabilitiesAsync(
        ReadOnlyMemory<float> completedPcm16KhzMono,
        int threadCount,
        CancellationToken cancellationToken);
}

public sealed class CompletedRecordingLanguageDetector(ILanguageProbabilityProvider probabilityProvider)
{
    public async Task<LanguageDecisionResult> DetectAsync(
        ReadOnlyMemory<float> completedPcm16KhzMono,
        LanguageProfile profile,
        SpeechLanguage? previousLanguage,
        int threadCount,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (completedPcm16KhzMono.IsEmpty)
        {
            throw new ArgumentException("A completed recording is required.", nameof(completedPcm16KhzMono));
        }
        if (threadCount < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(threadCount));
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (!profile.IsMixed)
        {
            return LanguageDecision.Choose(profile, new Dictionary<string, float>(StringComparer.Ordinal));
        }

        var probabilities = await probabilityProvider.DetectProbabilitiesAsync(
            completedPcm16KhzMono,
            threadCount,
            cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return LanguageDecision.Choose(profile, probabilities, previousLanguage);
    }
}
