using Witness.Core.Languages;
using Witness.Core.Text;

namespace Witness.Core.Review;

public enum RiskReasonKind
{
    Number,
    Date,
    Amount,
    NamedEntity,
    Glossary,
    MalformedWord,
    LanguageSwitch,
    CleanupEdit,
    Confidence,
}

public sealed record RiskSpan(
    RiskReasonKind Reason,
    TextRange RawRange,
    TextRange CleanedRange,
    double Weight,
    string Text,
    double? StartSeconds = null,
    double? EndSeconds = null,
    SpeechLanguage? Language = null,
    string? Detail = null,
    TextEditKind? CleanupKind = null,
    double? Confidence = null)
{
    public bool IsPlayable => StartSeconds is not null && EndSeconds is not null;
    public bool HasExtentInCleanedText => CleanedRange.Length > 0;
}

public sealed record ReviewPolicy
{
    public ReviewPolicy(double attentionThreshold = 0.8, double displayThreshold = 0.3)
    {
        AttentionThreshold = Math.Clamp(attentionThreshold, 0, 1);
        DisplayThreshold = Math.Min(Math.Clamp(displayThreshold, 0, 1), AttentionThreshold);
    }

    public double AttentionThreshold { get; }
    public double DisplayThreshold { get; }
    public static ReviewPolicy Default { get; } = new();
}

public sealed record ReviewDecision(bool DeservesAttention, IReadOnlyList<RiskSpan> Flagged, IReadOnlyList<RiskSpan> Highlighted)
{
    public bool HasAnythingToShow => Highlighted.Count > 0;
    public static ReviewDecision Quiet { get; } = new(false, Array.Empty<RiskSpan>(), Array.Empty<RiskSpan>());
}

public static class ReviewCoordinator
{
    public static ReviewDecision Decide(IEnumerable<RiskSpan> spans, bool isEmptyResult = false, ReviewPolicy? policy = null)
    {
        ArgumentNullException.ThrowIfNull(spans);
        if (isEmptyResult)
        {
            return ReviewDecision.Quiet;
        }
        policy ??= ReviewPolicy.Default;
        var materialized = spans.ToArray();
        var flagged = materialized.Where(span => span.Weight >= policy.AttentionThreshold).ToArray();
        var highlighted = materialized.Where(span => span.Weight >= policy.DisplayThreshold).ToArray();
        return flagged.Length == 0 && highlighted.Length == 0
            ? ReviewDecision.Quiet
            : new ReviewDecision(flagged.Length > 0, flagged, highlighted);
    }
}

public static class RiskPolicy
{
    public static readonly double ModelConfidenceWeight = 0;

    public static bool IsLanguageCalibrated(SpeechLanguage language) => language.IsVerified;

    public static bool CanUseLanguageSpecificSignal(SpeechLanguage language, RiskReasonKind reason) =>
        IsLanguageCalibrated(language) || reason is RiskReasonKind.Number or RiskReasonKind.Date or RiskReasonKind.Amount;
}
