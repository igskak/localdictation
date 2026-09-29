using Witness.Core.Languages;
using Witness.Core.Text;
using Witness.Core.Transcription;

namespace Witness.Core.Review;

public sealed record ProcessedDictation(
    string RawText,
    CleanupResult Cleanup,
    IReadOnlyList<RiskSpan> Risks,
    ReviewDecision Review,
    SpeechLanguage Language,
    LanguageProfile Profile)
{
    public string TextForInsertion => Cleanup.Cleaned;

    public bool RetainAudioForReview =>
        Review.DeservesAttention && Review.Flagged.Any(span => span.IsPlayable);
}

/// <summary>
/// Converts a completed local transcript into the exact text that may be
/// inserted and the optional review evidence shown after insertion. This type
/// is deliberately platform-free: it does not own audio, clipboard state,
/// persistence, UI, or network work.
/// </summary>
public sealed class DictationPostProcessor
{
    private readonly ConservativeCleanupService cleanup;
    private readonly RiskEngine riskEngine;
    private readonly ReviewPolicy reviewPolicy;

    public DictationPostProcessor(
        ConservativeCleanupService? cleanup = null,
        RiskEngine? riskEngine = null,
        ReviewPolicy? reviewPolicy = null)
    {
        this.cleanup = cleanup ?? new ConservativeCleanupService();
        this.riskEngine = riskEngine ?? RiskEngine.Standard();
        this.reviewPolicy = reviewPolicy ?? ReviewPolicy.Default;
    }

    public ProcessedDictation Process(
        MappedTranscript transcript,
        SpeechLanguage language,
        LanguageProfile profile,
        IReadOnlyList<GlossaryEntry>? glossary = null)
    {
        ArgumentNullException.ThrowIfNull(transcript);
        ArgumentNullException.ThrowIfNull(profile);
        if (!profile.Contains(language))
        {
            throw new ArgumentException(
                "The final speech language must belong to the selected profile.",
                nameof(language));
        }

        var cleaned = cleanup.Clean(transcript.Text, language);
        var tokens = transcript.Words.Select(word => new TranscriptToken(
            word.Text,
            word.GraphemeRange,
            word.Start.TotalSeconds,
            word.End.TotalSeconds,
            word.MeanTokenProbability)).ToArray();
        var risks = riskEngine.Analyze(cleaned, profile, tokens, glossary);
        var review = ReviewCoordinator.Decide(
            risks,
            isEmptyResult: string.IsNullOrWhiteSpace(cleaned.Cleaned),
            reviewPolicy);
        return new ProcessedDictation(
            transcript.Text,
            cleaned,
            risks,
            review,
            language,
            profile);
    }
}
