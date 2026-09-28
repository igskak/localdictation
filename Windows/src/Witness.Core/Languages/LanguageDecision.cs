namespace Witness.Core.Languages;

public sealed class LanguageProfile : IEquatable<LanguageProfile>
{
    private readonly SpeechLanguage[] _languages;

    public LanguageProfile(params SpeechLanguage[] languages)
        : this((IEnumerable<SpeechLanguage>)languages)
    {
    }

    public LanguageProfile(IEnumerable<SpeechLanguage> languages)
    {
        ArgumentNullException.ThrowIfNull(languages);
        _languages = languages.Distinct().ToArray();
        if (_languages.Length == 0 || _languages.Any(language => !LanguageCatalog.ByCode.ContainsKey(language.Code)))
        {
            throw new ArgumentException("A language profile must contain at least one engine language.", nameof(languages));
        }
    }

    public IReadOnlyList<SpeechLanguage> Languages => _languages;
    public SpeechLanguage Primary => _languages[0];
    public bool IsMixed => _languages.Length > 1;
    public string Id => string.Join('+', _languages.Select(language => language.Code));

    public bool Contains(SpeechLanguage language) => _languages.Contains(language);

    public LanguageProfile EffectiveForPin(SpeechLanguage? pin) => pin is SpeechLanguage language && Contains(language)
        ? new LanguageProfile(language)
        : this;

    public bool Equals(LanguageProfile? other) => other is not null && _languages.SequenceEqual(other._languages);
    public override bool Equals(object? obj) => obj is LanguageProfile other && Equals(other);
    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var language in _languages)
        {
            hash.Add(language);
        }
        return hash.ToHashCode();
    }
}

public enum LanguageDecisionReason
{
    OnlyLanguage,
    Confident,
    ContinuedFromPrevious,
    FellBackToPreferred,
    LeadWithoutMargin,
    NoEvidence,
}

public readonly record struct RankedLanguage(SpeechLanguage Language, float Probability);
public readonly record struct LanguageDecisionResult(SpeechLanguage Language, LanguageDecisionReason Reason);

public static class LanguageDecision
{
    public const float DefaultMargin = 0.2F;
    public static readonly TimeSpan RecencyWindow = TimeSpan.FromSeconds(120);

    public static LanguageDecisionResult Choose(
        LanguageProfile profile,
        IReadOnlyDictionary<string, float> probabilities,
        SpeechLanguage? previous = null,
        float margin = DefaultMargin)
    {
        ArgumentNullException.ThrowIfNull(profile);
        ArgumentNullException.ThrowIfNull(probabilities);
        if (!profile.IsMixed)
        {
            return new(profile.Primary, LanguageDecisionReason.OnlyLanguage);
        }

        var ranked = Rank(profile, probabilities);
        if (ranked.Count == 0)
        {
            return new(profile.Primary, LanguageDecisionReason.NoEvidence);
        }
        if (ranked.Count == 1)
        {
            return new(ranked[0].Language, LanguageDecisionReason.Confident);
        }

        var leader = ranked[0];
        var runnerUp = ranked[1];
        if (leader.Probability - runnerUp.Probability >= margin)
        {
            return new(leader.Language, LanguageDecisionReason.Confident);
        }

        if (previous is SpeechLanguage previousLanguage && (leader.Language == previousLanguage || runnerUp.Language == previousLanguage))
        {
            return new(previousLanguage, LanguageDecisionReason.ContinuedFromPrevious);
        }
        if (leader.Language == profile.Primary || runnerUp.Language == profile.Primary)
        {
            return new(profile.Primary, LanguageDecisionReason.FellBackToPreferred);
        }
        return new(leader.Language, LanguageDecisionReason.LeadWithoutMargin);
    }

    public static IReadOnlyList<RankedLanguage> Rank(LanguageProfile profile, IReadOnlyDictionary<string, float> probabilities) =>
        profile.Languages
            .Select((language, position) => (language, position, found: probabilities.TryGetValue(language.Code, out var probability), probability))
            .Where(item => item.found && float.IsFinite(item.probability))
            .Select(item => (item.language, item.position, probability: Math.Clamp(item.probability, 0, 1)))
            .OrderByDescending(item => item.probability)
            .ThenBy(item => item.position)
            .Select(item => new RankedLanguage(item.language, item.probability))
            .ToArray();
}

public sealed class LanguageContinuity
{
    private SpeechLanguage? _lastLanguage;
    private DateTimeOffset _lastAt;

    public void Observe(SpeechLanguage language, DateTimeOffset at)
    {
        _lastLanguage = language;
        _lastAt = at;
    }

    public SpeechLanguage? PreviousAt(DateTimeOffset now) =>
        _lastLanguage is not null && now >= _lastAt && now - _lastAt <= LanguageDecision.RecencyWindow
            ? _lastLanguage
            : null;

    public void Reset()
    {
        _lastLanguage = null;
        _lastAt = default;
    }
}
