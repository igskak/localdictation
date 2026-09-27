using System.Text;
using Witness.Core.Languages;
using Witness.Core.Text;

namespace Witness.Core.Review;

public sealed record GlossaryEntry(string Term, SpeechLanguage Language);

public sealed record TranscriptToken(
    string Text,
    TextRange Range,
    double StartSeconds,
    double EndSeconds,
    double? Confidence = null);

public sealed record RawRiskSpan(
    RiskReasonKind Reason,
    TextRange Range,
    string? Detail = null,
    SpeechLanguage? Language = null,
    TextEditKind? CleanupKind = null,
    double? Confidence = null)
{
    public string Category => Reason switch
    {
        RiskReasonKind.Number => "number",
        RiskReasonKind.Amount => "currency",
        RiskReasonKind.Date => "date",
        RiskReasonKind.NamedEntity => "entity",
        RiskReasonKind.Glossary => "glossary",
        RiskReasonKind.MalformedWord => "malformed",
        RiskReasonKind.LanguageSwitch => "language",
        RiskReasonKind.CleanupEdit => $"cleanup.{CleanupKind?.ToString().ToLowerInvariant() ?? "unknown"}",
        RiskReasonKind.Confidence => "confidence",
        _ => throw new ArgumentOutOfRangeException(),
    };
}

public sealed record RiskWeights
{
    public double Number { get; init; } = 0.8;
    public double Currency { get; init; } = 0.8;
    public double Date { get; init; } = 0.8;
    public double NamedEntity { get; init; } = 0.6;
    public double GlossaryNearMiss { get; init; } = 0.9;
    public double MalformedWord { get; init; } = 0.85;
    public double CleanupFillerRemoval { get; init; } = 0.6;
    public double CleanupPunctuation { get; init; } = 0.05;
    public double CleanupCapitalization { get; init; } = 0.05;
    public double CleanupSpacing { get; init; }
    public double LanguageOutsideProfile { get; init; } = 0.7;
    public double LanguageSecondaryOfProfile { get; init; } = 0.3;
    public double ModelConfidence { get; init; }
    public double ConfidenceThreshold { get; init; } = 0.5;

    public static RiskWeights Default { get; } = new();

    public double Weight(RawRiskSpan span, LanguageProfile profile) => span.Reason switch
    {
        RiskReasonKind.Number => Number,
        RiskReasonKind.Amount => Currency,
        RiskReasonKind.Date => Date,
        RiskReasonKind.NamedEntity => NamedEntity,
        RiskReasonKind.Glossary => GlossaryNearMiss,
        RiskReasonKind.MalformedWord => MalformedWord,
        RiskReasonKind.CleanupEdit => span.CleanupKind switch
        {
            TextEditKind.FillerRemoval => CleanupFillerRemoval,
            TextEditKind.Punctuation => CleanupPunctuation,
            TextEditKind.Capitalization => CleanupCapitalization,
            TextEditKind.Spacing => CleanupSpacing,
            _ => 0,
        },
        RiskReasonKind.LanguageSwitch => span.Language is SpeechLanguage language && profile.Contains(language)
            ? LanguageSecondaryOfProfile
            : LanguageOutsideProfile,
        RiskReasonKind.Confidence => ModelConfidence * ConfidenceSeverity(span.Confidence ?? 1),
        _ => throw new ArgumentOutOfRangeException(),
    };

    public double ConfidenceSeverity(double value)
    {
        if (ConfidenceThreshold <= 0) return 0;
        return Math.Clamp((ConfidenceThreshold - value) / ConfidenceThreshold, 0, 1);
    }
}

public sealed class RiskContext
{
    public RiskContext(
        string raw,
        LanguageProfile profile,
        SpeechLanguage? language = null,
        IReadOnlyList<TranscriptToken>? tokens = null,
        IReadOnlyList<TextEdit>? edits = null,
        IReadOnlyList<GlossaryEntry>? glossary = null)
    {
        Raw = raw ?? throw new ArgumentNullException(nameof(raw));
        Profile = profile ?? throw new ArgumentNullException(nameof(profile));
        Language = language ?? profile.Primary;
        Words = WordScanner.Words(raw);
        Tokens = tokens ?? Array.Empty<TranscriptToken>();
        Edits = edits ?? Array.Empty<TextEdit>();
        Glossary = glossary ?? Array.Empty<GlossaryEntry>();
    }

    public string Raw { get; }
    public IReadOnlyList<TextWord> Words { get; }
    public IReadOnlyList<TranscriptToken> Tokens { get; }
    public LanguageProfile Profile { get; }
    public SpeechLanguage Language { get; }
    public IReadOnlyList<TextEdit> Edits { get; }
    public IReadOnlyList<GlossaryEntry> Glossary { get; }

    public bool IsInGlossary(string lowercasedWord) => Glossary.Any(entry =>
        Profile.Contains(entry.Language)
        && string.Equals(entry.Term.ToLowerInvariant(), lowercasedWord, StringComparison.Ordinal));
}

public interface IRiskSignal
{
    string Identifier { get; }
    IReadOnlyList<RawRiskSpan> Spans(RiskContext context);
}

public enum CriticalTokenCategory
{
    Number,
    Currency,
    Date,
}

public static class CriticalTokens
{
    private static readonly HashSet<Rune> CurrencySymbols = Runes("€$£₴₽¥");
    private static readonly HashSet<string> CurrencyWords = Set(
        "euro", "eur", "cent", "cents", "dollar", "dollars", "usd", "pfund", "pound",
        "евро", "євро", "гривень", "гривня", "гривні", "рублей", "рубль", "рубля",
        "центов", "долларов", "доларів");
    private static readonly HashSet<string> NumberWords = Set(
        "null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
        "elf", "zwölf", "zwanzig", "dreißig", "vierzig", "fünfzig", "hundert", "tausend", "million",
        "zweitausend", "zweitausendfünfhundert", "fünfhundert",
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million",
        "ноль", "один", "одна", "два", "две", "три", "четыре", "пять", "шесть", "семь", "восемь",
        "девять", "десять", "двадцать", "тридцать", "сорок", "пятьдесят", "сто", "двести",
        "пятьсот", "тысяча", "тысячи", "тысяч", "миллион",
        "нуль", "одне", "чотири", "п'ять", "шість", "сім", "вісім", "дев'ять",
        "двадцять", "тридцять", "п'ятдесят", "двісті", "п'ятсот", "тисяча", "тисячі", "тисяч", "мільйон");
    private static readonly HashSet<string> DateMarkers = Set(
        "am", "vom", "zum", "bis", "ab", "seit", "nach",
        "on", "by", "until", "till", "after", "before", "since",
        "до", "с", "по", "к", "после", "числа", "з", "після");
    private static readonly HashSet<string> Weekdays = Set(
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonnabend", "sonntag",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "понедельник", "понедельника", "вторник", "вторника", "среда", "среду", "среды",
        "четверг", "четверга", "пятница", "пятницу", "пятницы", "суббота", "субботу", "субботы",
        "воскресенье", "воскресенья", "понеділок", "понеділка", "вівторок", "вівторка", "середа",
        "середу", "середи", "четвер", "п'ятниця", "п'ятницю", "п'ятниці", "субота", "суботу",
        "суботи", "неділя", "неділю", "неділі");
    private static readonly HashSet<string> Months = Set(
        "januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember",
        "january", "february", "march", "may", "june", "july", "october", "december",
        "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря",
        "січня", "лютого", "березня", "квітня", "травня", "червня", "липня", "серпня", "вересня", "жовтня", "листопада", "грудня");
    private static readonly HashSet<string> Ordinals = Set(
        "ersten", "zweiten", "dritten", "vierten", "fünften", "sechsten", "siebten", "achten", "neunten", "zehnten", "elften", "zwölften", "fünfzehnten", "zwanzigsten",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "fifteenth", "twentieth",
        "первого", "второго", "третьего", "четвёртого", "четвертого", "пятого", "шестого", "седьмого", "восьмого", "девятого", "десятого", "пятнадцатого", "двадцатого",
        "першого", "другого", "третього", "четвертого", "п'ятого", "шостого", "сьомого", "восьмого", "дев'ятого", "десятого", "п'ятнадцятого", "двадцятого");

    public const int DateContextWindow = 2;

    public static bool ContainsDigit(string word) => word.EnumerateRunes().Any(Rune.IsNumber);
    public static bool IsCurrency(string word) => word.EnumerateRunes().Any(CurrencySymbols.Contains) || CurrencyWords.Contains(word.ToLowerInvariant());
    public static bool IsNumeric(string word) => ContainsDigit(word) || IsCurrency(word) || NumberWords.Contains(word.ToLowerInvariant());
    public static bool IsDate(string word, IEnumerable<string>? previous = null, IEnumerable<string>? next = null)
    {
        var lower = word.ToLowerInvariant();
        if (Months.Contains(lower) || Weekdays.Contains(lower)) return true;
        if (!Ordinals.Contains(lower)) return false;
        var before = (previous ?? Array.Empty<string>()).Select(value => value.ToLowerInvariant()).ToArray();
        var after = (next ?? Array.Empty<string>()).Select(value => value.ToLowerInvariant()).ToArray();
        return before.Concat(after).Any(Months.Contains) || before.Any(DateMarkers.Contains);
    }

    public static CriticalTokenCategory? Category(string word, IEnumerable<string>? previous = null, IEnumerable<string>? next = null)
    {
        if (IsCurrency(word)) return CriticalTokenCategory.Currency;
        if (IsDate(word, previous, next)) return CriticalTokenCategory.Date;
        if (IsNumeric(word)) return CriticalTokenCategory.Number;
        return null;
    }

    private static HashSet<string> Set(params string[] values) => new(values, StringComparer.Ordinal);
    private static HashSet<Rune> Runes(string value) => value.EnumerateRunes().ToHashSet();
}

public sealed class NumberRiskSignal : IRiskSignal
{
    public string Identifier => "numbers";
    public IReadOnlyList<RawRiskSpan> Spans(RiskContext context)
    {
        var result = new List<RawRiskSpan>();
        for (var index = 0; index < context.Words.Count; index++)
        {
            var previous = context.Words.Skip(Math.Max(0, index - CriticalTokens.DateContextWindow)).Take(Math.Min(index, CriticalTokens.DateContextWindow)).Select(word => word.Text);
            var next = context.Words.Skip(index + 1).Take(CriticalTokens.DateContextWindow).Select(word => word.Text);
            var category = CriticalTokens.Category(context.Words[index].Text, previous, next);
            if (category is null) continue;
            var reason = category switch
            {
                CriticalTokenCategory.Number => RiskReasonKind.Number,
                CriticalTokenCategory.Currency => RiskReasonKind.Amount,
                CriticalTokenCategory.Date => RiskReasonKind.Date,
                _ => throw new ArgumentOutOfRangeException(),
            };
            result.Add(new RawRiskSpan(reason, context.Words[index].Range));
        }
        return result;
    }
}

public sealed class EntityRiskSignal : IRiskSignal
{
    private static readonly IReadOnlyDictionary<SpeechLanguage, IReadOnlySet<string>> TitleMarkers =
        new Dictionary<SpeechLanguage, IReadOnlySet<string>>
        {
            [SpeechLanguage.German] = Set("herr", "frau", "dr", "prof", "familie"),
            [SpeechLanguage.English] = Set("mr", "mrs", "ms", "miss", "dr", "prof", "professor"),
            [SpeechLanguage.Russian] = Set("господин", "госпожа", "г-н", "г-жа", "доктор", "профессор"),
            [SpeechLanguage.Ukrainian] = Set("пан", "пані", "добродій", "доктор", "професор"),
        };

    public string Identifier => "entities";
    public static bool UsesCapitalizationHeuristic(SpeechLanguage language) => !language.CapitalizesNouns;

    public IReadOnlyList<RawRiskSpan> Spans(RiskContext context)
    {
        var markers = TitleMarkers.TryGetValue(context.Language, out var found) ? found : Set();
        var useCapitalization = UsesCapitalizationHeuristic(context.Language);
        var previousWasMarker = false;
        var result = new List<RawRiskSpan>();
        foreach (var word in context.Words)
        {
            var isCurrentMarker = markers.Contains(word.Lowercased);
            if (!CriticalTokens.ContainsDigit(word.Text) && !context.IsInGlossary(word.Lowercased))
            {
                var first = word.Text.EnumerateRunes().FirstOrDefault();
                var isUpper = Rune.IsUpper(first);
                if (previousWasMarker && isUpper)
                {
                    result.Add(new RawRiskSpan(RiskReasonKind.NamedEntity, word.Range));
                }
                else if (IsAcronym(word.Text))
                {
                    result.Add(new RawRiskSpan(RiskReasonKind.NamedEntity, word.Range));
                }
                else if (useCapitalization && !word.IsSentenceInitial && isUpper
                    && !(context.Language == SpeechLanguage.English && word.Lowercased == "i"))
                {
                    result.Add(new RawRiskSpan(RiskReasonKind.NamedEntity, word.Range));
                }
            }
            previousWasMarker = isCurrentMarker;
        }
        return result;
    }

    private static bool IsAcronym(string word)
    {
        var runes = word.EnumerateRunes().ToArray();
        return runes.Length >= 2 && runes.All(rune => Rune.IsUpper(rune) || Rune.IsNumber(rune));
    }

    private static IReadOnlySet<string> Set(params string[] values) => new HashSet<string>(values, StringComparer.Ordinal);
}

public sealed class GlossaryRiskSignal : IRiskSignal
{
    public string Identifier => "glossary";
    public static int AllowedDistance(int termLength) => termLength < 4 ? 1 : termLength < 8 ? 2 : 3;

    public IReadOnlyList<RawRiskSpan> Spans(RiskContext context)
    {
        var terms = context.Glossary.Where(entry => context.Profile.Contains(entry.Language)).ToArray();
        if (terms.Length == 0) return Array.Empty<RawRiskSpan>();
        var result = new List<RawRiskSpan>();
        foreach (var word in context.Words)
        {
            var candidate = word.Lowercased;
            (string Term, int Distance)? best = null;
            foreach (var entry in terms)
            {
                var term = entry.Term.ToLowerInvariant();
                if (term.Length == 0) continue;
                if (string.Equals(term, candidate, StringComparison.Ordinal))
                {
                    best = null;
                    break;
                }
                var termLength = new TextIndexMap(term).GraphemeCount;
                var distance = EditDistance.Bounded(candidate, term, AllowedDistance(termLength));
                if (distance is null or 0) continue;
                if (best is null || distance.Value < best.Value.Distance) best = (entry.Term, distance.Value);
            }
            if (best is not null) result.Add(new RawRiskSpan(RiskReasonKind.Glossary, word.Range, best.Value.Term));
        }
        return result;
    }
}

public sealed class CleanupEditRiskSignal : IRiskSignal
{
    public string Identifier => "cleanup";
    public IReadOnlyList<RawRiskSpan> Spans(RiskContext context) =>
        context.Edits.Select(edit => new RawRiskSpan(RiskReasonKind.CleanupEdit, edit.RawRange, CleanupKind: edit.Kind)).ToArray();
}

public sealed class LanguageSwitchRiskSignal : IRiskSignal
{
    public string Identifier => "language";
    public IReadOnlyList<RawRiskSpan> Spans(RiskContext context)
    {
        var result = new List<RawRiskSpan>();
        foreach (var word in context.Words)
        {
            if (!word.Text.EnumerateRunes().Any(Rune.IsLetter)) continue;
            if (!LanguageIdentifier.ScriptMatches(word.Text, context.Profile))
            {
                var language = LanguageIdentifier.Language(word.Text)
                    ?? (LanguageIdentifier.Script(word.Text) == TextScript.Cyrillic ? SpeechLanguage.Russian : SpeechLanguage.English);
                result.Add(new RawRiskSpan(RiskReasonKind.LanguageSwitch, word.Range, Language: language));
                continue;
            }
            if (!context.Profile.Languages.All(language => language.IsVerified)) continue;
            var identified = LanguageIdentifier.Language(word.Text);
            if (identified is not null && identified.Value != context.Language)
                result.Add(new RawRiskSpan(RiskReasonKind.LanguageSwitch, word.Range, Language: identified));
        }
        return result;
    }
}

public interface ILexicon
{
    bool Supports(SpeechLanguage language);
    bool IsKnownWord(string word, SpeechLanguage language);
}

public sealed class EmptyLexicon : ILexicon
{
    public bool Supports(SpeechLanguage language) => false;
    public bool IsKnownWord(string word, SpeechLanguage language) => false;
}

public sealed class ShapeOnlyLexicon : ILexicon
{
    public bool Supports(SpeechLanguage language) => true;
    public bool IsKnownWord(string word, SpeechLanguage language) => false;
}

public sealed class MalformedWordSignal(ILexicon lexicon) : IRiskSignal
{
    private static readonly HashSet<Rune> Vowels = Runes("aeiouyäöüаеёиоуыэюяіїє");
    private static readonly HashSet<Rune> Neutral = Runes("ьъ'’");
    private const int MinimumLength = 4;

    public string Identifier => "malformed";
    public IReadOnlyList<RawRiskSpan> Spans(RiskContext context)
    {
        if (!context.Language.IsVerified || !lexicon.Supports(context.Language)) return Array.Empty<RawRiskSpan>();
        return context.Words.Where(word =>
                word.Text.EnumerateRunes().Count() >= MinimumLength
                && !CriticalTokens.ContainsDigit(word.Text)
                && !IsAcronym(word.Text)
                && !context.IsInGlossary(word.Lowercased)
                && HasImpossibleShape(word.Text, context.Language)
                && !lexicon.IsKnownWord(word.Text, context.Language))
            .Select(word => new RawRiskSpan(RiskReasonKind.MalformedWord, word.Range))
            .ToArray();
    }

    public static bool IsAcronym(string word)
    {
        var runes = word.EnumerateRunes().ToArray();
        return runes.Length >= 2 && runes.All(rune => Rune.IsUpper(rune) || Rune.IsNumber(rune));
    }

    public static bool UsesConsonantRunRule(SpeechLanguage language) => language != SpeechLanguage.German;

    public static bool HasImpossibleShape(string word, SpeechLanguage language)
    {
        var letters = word.ToLowerInvariant().EnumerateRunes().Where(Rune.IsLetter).ToArray();
        if (letters.Length < MinimumLength) return false;
        if (letters.Length >= 2 && IsConsonant(letters[0]) && letters[0] == letters[1]) return true;
        var run = 0;
        var sawVowel = false;
        foreach (var rune in letters)
        {
            if (Vowels.Contains(rune))
            {
                sawVowel = true;
                run = 0;
            }
            else if (!IsConsonant(rune))
            {
                run = 0;
            }
            else if (++run > 5 && UsesConsonantRunRule(language))
            {
                return true;
            }
        }
        return !sawVowel;
    }

    private static bool IsConsonant(Rune rune) => Rune.IsLetter(rune) && !Vowels.Contains(rune) && !Neutral.Contains(rune);
    private static HashSet<Rune> Runes(string value) => value.EnumerateRunes().ToHashSet();
}

public sealed class ConfidenceRiskSignal(double threshold = 0.5) : IRiskSignal
{
    public string Identifier => "confidence";
    public IReadOnlyList<RawRiskSpan> Spans(RiskContext context) => context.Tokens
        .Where(token => token.Confidence is not null && token.Confidence <= threshold && token.Range.Length > 0)
        .Select(token => new RawRiskSpan(RiskReasonKind.Confidence, token.Range, Confidence: token.Confidence))
        .ToArray();
}

public sealed class RiskEngine
{
    public RiskEngine(IEnumerable<IRiskSignal> signals, RiskWeights? weights = null)
    {
        Signals = signals?.ToArray() ?? throw new ArgumentNullException(nameof(signals));
        Weights = weights ?? RiskWeights.Default;
    }

    public IReadOnlyList<IRiskSignal> Signals { get; }
    public RiskWeights Weights { get; }

    public static RiskEngine Standard(RiskWeights? weights = null, ILexicon? lexicon = null)
    {
        weights ??= RiskWeights.Default;
        return new RiskEngine(
        [
            new NumberRiskSignal(),
            new EntityRiskSignal(),
            new GlossaryRiskSignal(),
            new MalformedWordSignal(lexicon ?? new EmptyLexicon()),
            new CleanupEditRiskSignal(),
            new LanguageSwitchRiskSignal(),
            new ConfidenceRiskSignal(weights.ConfidenceThreshold),
        ], weights);
    }

    public IReadOnlyList<RiskSpan> Analyze(
        CleanupResult cleanup,
        LanguageProfile profile,
        IReadOnlyList<TranscriptToken>? tokens = null,
        IReadOnlyList<GlossaryEntry>? glossary = null)
    {
        ArgumentNullException.ThrowIfNull(cleanup);
        ArgumentNullException.ThrowIfNull(profile);
        tokens ??= Array.Empty<TranscriptToken>();
        var context = new RiskContext(cleanup.Raw, profile, cleanup.Language, tokens, cleanup.Edits, glossary);
        var rawSpans = SuppressRedundantEntities(Signals.SelectMany(signal => signal.Spans(context)));
        var seen = new HashSet<(TextRange Range, string Category)>();
        var result = new List<RiskSpan>();
        var cleanedMap = new TextIndexMap(cleanup.Cleaned);
        foreach (var raw in rawSpans)
        {
            if (!seen.Add((raw.Range, raw.Category))) continue;
            var cleanedRange = cleanup.Map.CleanedRangeForRaw(raw.Range);
            var window = AudioWindow(raw.Range, tokens);
            var text = cleanedRange.Start >= 0 && cleanedRange.End <= cleanedMap.GraphemeCount && cleanedRange.Length > 0
                ? cleanedMap.Slice(cleanedRange)
                : string.Empty;
            result.Add(new RiskSpan(
                raw.Reason,
                raw.Range,
                cleanedRange,
                Weights.Weight(raw, profile),
                text,
                window?.Start,
                window?.End,
                raw.Language,
                raw.Detail,
                raw.CleanupKind,
                raw.Confidence));
        }
        return result.OrderBy(span => span.CleanedRange.Start).ThenByDescending(span => span.Weight).ToArray();
    }

    public static IReadOnlyList<RawRiskSpan> SuppressRedundantEntities(IEnumerable<RawRiskSpan> rawSpans)
    {
        var materialized = rawSpans.ToArray();
        var explained = materialized.Where(span => span.Reason != RiskReasonKind.NamedEntity).Select(span => span.Range).ToArray();
        if (explained.Length == 0) return materialized;
        return materialized.Where(span => span.Reason != RiskReasonKind.NamedEntity || !explained.Any(range => Overlaps(range, span.Range))).ToArray();
    }

    public static (double Start, double End)? AudioWindow(TextRange range, IReadOnlyList<TranscriptToken> tokens)
    {
        double? start = null;
        double? end = null;
        foreach (var token in tokens)
        {
            var overlaps = range.Length == 0
                ? (Contains(token.Range, range.Start) || token.Range.End == range.Start)
                : Overlaps(token.Range, range);
            if (!overlaps) continue;
            start = Math.Min(start ?? token.StartSeconds, token.StartSeconds);
            end = Math.Max(end ?? token.EndSeconds, token.EndSeconds);
        }
        return start is not null && end is not null && end >= start ? (start.Value, end.Value) : null;
    }

    private static bool Contains(TextRange range, int offset) => offset >= range.Start && offset < range.End;
    private static bool Overlaps(TextRange left, TextRange right) => left.Start < right.End && right.Start < left.End;
}
