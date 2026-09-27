using System.Globalization;
using System.Text;
using Witness.Core.Languages;

namespace Witness.Core.Text;

public enum TextEditKind
{
    Spacing,
    Punctuation,
    Capitalization,
    FillerRemoval,
}

public sealed record TextEdit(TextEditKind Kind, TextRange RawRange, TextRange CleanedRange, string RawText, string CleanedText)
{
    public bool RemovesSpokenWords => Kind == TextEditKind.FillerRemoval;
}

public sealed record EditMapSegment(TextRange Raw, TextRange Cleaned, bool IsEdit);

public sealed class EditMap
{
    public EditMap(IReadOnlyList<EditMapSegment> segments, int rawLength, int cleanedLength)
    {
        Segments = segments;
        RawLength = rawLength;
        CleanedLength = cleanedLength;
    }

    public IReadOnlyList<EditMapSegment> Segments { get; }
    public int RawLength { get; }
    public int CleanedLength { get; }
    public bool HasEdits => Segments.Any(segment => segment.IsEdit);

    public static EditMap Identity(int length) => new(
        length > 0 ? [new EditMapSegment(new TextRange(0, length), new TextRange(0, length), false)] : [],
        length,
        length);

    public TextRange CleanedRangeForRaw(TextRange range)
    {
        var lower = CleanedStartForRaw(range.Start);
        var upper = CleanedEndForRaw(range.End);
        return new(lower, Math.Max(lower, upper) - lower);
    }

    public TextRange RawRangeForCleaned(TextRange range)
    {
        var lower = RawStartForCleaned(range.Start);
        var upper = RawEndForCleaned(range.End);
        return new(lower, Math.Max(lower, upper) - lower);
    }

    private int CleanedStartForRaw(int offset)
    {
        offset = Math.Clamp(offset, 0, RawLength);
        foreach (var segment in Segments.Where(segment => segment.Raw.End > offset))
        {
            if (segment.Raw.Start > offset) return segment.Cleaned.Start;
            if (segment.IsEdit) return segment.Cleaned.Start;
            return segment.Cleaned.Start + offset - segment.Raw.Start;
        }
        return CleanedLength;
    }

    private int CleanedEndForRaw(int offset)
    {
        offset = Math.Clamp(offset, 0, RawLength);
        if (offset == 0) return 0;
        foreach (var segment in Segments.Reverse().Where(segment => segment.Raw.Start < offset))
        {
            if (segment.IsEdit) return segment.Cleaned.End;
            return Math.Min(segment.Cleaned.Start + offset - segment.Raw.Start, segment.Cleaned.End);
        }
        return 0;
    }

    private int RawStartForCleaned(int offset)
    {
        offset = Math.Clamp(offset, 0, CleanedLength);
        foreach (var segment in Segments.Where(segment => segment.Cleaned.End > offset))
        {
            if (segment.Cleaned.Start > offset) return segment.Raw.Start;
            if (segment.IsEdit) return segment.Raw.Start;
            return segment.Raw.Start + offset - segment.Cleaned.Start;
        }
        return RawLength;
    }

    private int RawEndForCleaned(int offset)
    {
        offset = Math.Clamp(offset, 0, CleanedLength);
        if (offset == 0) return 0;
        foreach (var segment in Segments.Reverse().Where(segment => segment.Cleaned.Start < offset))
        {
            if (segment.IsEdit) return segment.Raw.End;
            return Math.Min(segment.Raw.Start + offset - segment.Cleaned.Start, segment.Raw.End);
        }
        return 0;
    }
}

public sealed record CleanupOptions(
    bool CollapsesWhitespace = true,
    bool FixesPunctuationSpacing = true,
    bool RemovesFillers = true,
    bool CapitalizesSentences = true,
    bool AddsTerminalPunctuation = true)
{
    public static CleanupOptions Default { get; } = new();
    public static CleanupOptions None { get; } = new(false, false, false, false, false);
    public static CleanupOptions ForLanguage(SpeechLanguage language) => language.IsVerified ? Default : None;
}

public sealed record CleanupResult(
    string Raw,
    string Cleaned,
    IReadOnlyList<TextEdit> Edits,
    EditMap Map,
    SpeechLanguage Language)
{
    public bool DidChangeText => !string.Equals(Raw, Cleaned, StringComparison.Ordinal);
    public IReadOnlyList<TextEdit> WordRemovingEdits => Edits.Where(edit => edit.RemovesSpokenWords).ToArray();

    public static CleanupResult Unchanged(string text, SpeechLanguage language) =>
        new(text, text, Array.Empty<TextEdit>(), EditMap.Identity(new TextIndexMap(text).GraphemeCount), language);
}

public sealed record TextWord(int Index, string Text, TextRange Range, bool IsSentenceInitial)
{
    public string Lowercased => Text.ToLowerInvariant();
}

public static class WordScanner
{
    private static readonly HashSet<string> SentenceTerminators = [".", "!", "?", "…"];
    private static readonly HashSet<string> Joiners = ["'", "’", "ʼ", "-", "‑"];
    private static readonly HashSet<string> CurrencySymbols = ["€", "$", "£", "₴", "₽", "¥"];

    public static IReadOnlyList<TextWord> Words(string text)
    {
        var characters = Graphemes(text);
        var words = new List<TextWord>();
        var wordIndex = 0;
        var sentenceIsOpen = false;
        var position = 0;
        while (position < characters.Count)
        {
            var character = characters[position];
            if (!IsWordStart(character))
            {
                if (SentenceTerminators.Contains(character)) sentenceIsOpen = false;
                position++;
                continue;
            }
            var start = position++;
            while (position < characters.Count && IsWordContinuation(characters, position)) position++;
            words.Add(new TextWord(
                wordIndex++,
                string.Concat(characters.Skip(start).Take(position - start)),
                new TextRange(start, position - start),
                !sentenceIsOpen));
            sentenceIsOpen = true;
        }
        return words;
    }

    internal static IReadOnlyList<string> Graphemes(string text)
    {
        var result = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext()) result.Add(enumerator.GetTextElement());
        return result;
    }

    internal static bool IsLetter(string value) => value.EnumerateRunes().FirstOrDefault() is var rune && Rune.IsLetter(rune);
    internal static bool IsNumber(string value) => value.EnumerateRunes().FirstOrDefault() is var rune && Rune.IsNumber(rune);
    internal static bool IsWhitespace(string value) => value.All(char.IsWhiteSpace);
    internal static bool IsLowercase(string value) => value.EnumerateRunes().FirstOrDefault() is var rune && Rune.IsLower(rune);

    private static bool IsWordStart(string character) => IsLetter(character) || IsNumber(character) || CurrencySymbols.Contains(character);

    private static bool IsWordContinuation(IReadOnlyList<string> characters, int position)
    {
        var character = characters[position];
        if (IsWordStart(character)) return true;
        if (Joiners.Contains(character)) return position + 1 < characters.Count && IsWordStart(characters[position + 1]);
        if (character is "." or "," or ":")
        {
            return position > 0 && IsNumber(characters[position - 1])
                && position + 1 < characters.Count && IsNumber(characters[position + 1]);
        }
        return false;
    }
}

public sealed class ConservativeCleanupService
{
    private static readonly IReadOnlyDictionary<string, IReadOnlySet<string>> Fillers = new Dictionary<string, IReadOnlySet<string>>(StringComparer.Ordinal)
    {
        ["de"] = new HashSet<string>(["äh", "ähm", "öhm", "hm", "hmm", "mhm"], StringComparer.Ordinal),
        ["en"] = new HashSet<string>(["uh", "uhm", "um", "erm", "hmm", "mhm"], StringComparer.Ordinal),
        ["ru"] = new HashSet<string>(["ээ", "эээ", "эм", "ммм", "мм"], StringComparer.Ordinal),
        ["uk"] = new HashSet<string>(["ее", "еее", "ем", "ммм", "мм"], StringComparer.Ordinal),
    };
    private static readonly HashSet<string> SentenceTerminators = [".", "!", "?", "…"];
    private static readonly HashSet<string> ClosingPunctuation = [".", ",", "!", "?", ";", ":", "…"];

    private sealed record Replacement(TextRange Range, string Text, TextEditKind Kind);
    private sealed record FillerRemoval(int WordIndex, Replacement Replacement);

    public CleanupResult Clean(string raw, SpeechLanguage language, CleanupOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(raw);
        options ??= CleanupOptions.ForLanguage(language);
        var characters = WordScanner.Graphemes(raw);
        if (characters.Count == 0) return CleanupResult.Unchanged(raw, language);
        var words = WordScanner.Words(raw);
        var replacements = new List<Replacement>();
        var claimed = new List<TextRange>();

        void Accept(Replacement replacement)
        {
            if (claimed.Any(range => Overlaps(range, replacement.Range))) return;
            if (string.Concat(characters.Skip(replacement.Range.Start).Take(replacement.Range.Length)) == replacement.Text) return;
            replacements.Add(replacement);
            claimed.Add(replacement.Range);
        }

        HashSet<int> removed;
        if (options.RemovesFillers)
        {
            var removals = FillerRemovals(characters, words, language);
            removed = removals.Select(removal => removal.WordIndex).ToHashSet();
            foreach (var removal in removals) Accept(removal.Replacement);
        }
        else removed = [];

        if (options.FixesPunctuationSpacing) foreach (var replacement in PunctuationSpacing(characters)) Accept(replacement);
        if (options.CollapsesWhitespace) foreach (var replacement in WhitespaceCollapsing(characters)) Accept(replacement);
        if (options.CapitalizesSentences) foreach (var replacement in SentenceCapitalization(characters, words, removed)) Accept(replacement);
        if (options.AddsTerminalPunctuation && TerminalPunctuation(characters) is Replacement terminal) Accept(terminal);

        var ordered = replacements.OrderBy(item => item.Range.Start).ThenBy(item => item.Range.Length == 0 ? 0 : 1).ToArray();
        return Apply(ordered, characters, raw, language);
    }

    private static IReadOnlyList<FillerRemoval> FillerRemovals(IReadOnlyList<string> characters, IReadOnlyList<TextWord> words, SpeechLanguage language)
    {
        if (!Fillers.TryGetValue(language.Code, out var vocabulary)) return [];
        var result = new List<FillerRemoval>();
        foreach (var word in words.Where(word => vocabulary.Contains(word.Lowercased)))
        {
            var lower = word.Range.Start;
            var upper = word.Range.End;
            if (upper < characters.Count && characters[upper] == " ") upper++;
            else if (lower > 0 && characters[lower - 1] == " ") lower--;
            result.Add(new FillerRemoval(word.Index, new Replacement(new TextRange(lower, upper - lower), string.Empty, TextEditKind.FillerRemoval)));
        }
        return result;
    }

    private static IEnumerable<Replacement> PunctuationSpacing(IReadOnlyList<string> characters)
    {
        var position = 0;
        while (position < characters.Count)
        {
            var character = characters[position];
            if (WordScanner.IsWhitespace(character))
            {
                var end = position;
                while (end < characters.Count && WordScanner.IsWhitespace(characters[end])) end++;
                if (end < characters.Count && ClosingPunctuation.Contains(characters[end]) && end > position)
                    yield return new Replacement(new TextRange(position, end - position), string.Empty, TextEditKind.Spacing);
                position = end;
                continue;
            }
            if (ClosingPunctuation.Contains(character) && position + 1 < characters.Count && WordScanner.IsLetter(characters[position + 1]))
                yield return new Replacement(new TextRange(position + 1, 0), " ", TextEditKind.Spacing);
            position++;
        }
    }

    private static IEnumerable<Replacement> WhitespaceCollapsing(IReadOnlyList<string> characters)
    {
        var position = 0;
        while (position < characters.Count)
        {
            if (!WordScanner.IsWhitespace(characters[position])) { position++; continue; }
            var end = position;
            while (end < characters.Count && WordScanner.IsWhitespace(characters[end])) end++;
            var replacement = position == 0 || end == characters.Count ? string.Empty : " ";
            var current = string.Concat(characters.Skip(position).Take(end - position));
            if (current != replacement) yield return new Replacement(new TextRange(position, end - position), replacement, TextEditKind.Spacing);
            position = end;
        }
    }

    private static IEnumerable<Replacement> SentenceCapitalization(IReadOnlyList<string> characters, IReadOnlyList<TextWord> words, IReadOnlySet<int> removed)
    {
        var expectsStart = true;
        foreach (var word in words)
        {
            if (removed.Contains(word.Index)) continue;
            if (expectsStart && WordScanner.IsLowercase(word.Text))
            {
                var first = characters[word.Range.Start];
                var upper = first.ToUpperInvariant();
                if (new TextIndexMap(upper).GraphemeCount == 1)
                    yield return new Replacement(new TextRange(word.Range.Start, 1), upper, TextEditKind.Capitalization);
                expectsStart = false;
            }
            else if (expectsStart) expectsStart = false;

            var position = word.Range.End;
            while (position < characters.Count && !WordScanner.IsLetter(characters[position]) && !WordScanner.IsNumber(characters[position]))
            {
                if (SentenceTerminators.Contains(characters[position])) expectsStart = true;
                position++;
            }
        }
    }

    private static Replacement? TerminalPunctuation(IReadOnlyList<string> characters)
    {
        var end = characters.Count;
        while (end > 0 && WordScanner.IsWhitespace(characters[end - 1])) end--;
        if (end == 0) return null;
        var last = characters[end - 1];
        return WordScanner.IsLetter(last) || WordScanner.IsNumber(last)
            ? new Replacement(new TextRange(end, 0), ".", TextEditKind.Punctuation)
            : null;
    }

    private static CleanupResult Apply(IReadOnlyList<Replacement> replacements, IReadOnlyList<string> characters, string raw, SpeechLanguage language)
    {
        if (replacements.Count == 0) return CleanupResult.Unchanged(raw, language);
        var cleaned = new StringBuilder();
        var edits = new List<TextEdit>();
        var segments = new List<EditMapSegment>();
        var rawPosition = 0;
        var cleanedPosition = 0;
        foreach (var replacement in replacements)
        {
            if (replacement.Range.Start < rawPosition) continue;
            if (replacement.Range.Start > rawPosition)
            {
                var carried = string.Concat(characters.Skip(rawPosition).Take(replacement.Range.Start - rawPosition));
                var carriedCount = new TextIndexMap(carried).GraphemeCount;
                cleaned.Append(carried);
                segments.Add(new EditMapSegment(new TextRange(rawPosition, replacement.Range.Start - rawPosition), new TextRange(cleanedPosition, carriedCount), false));
                cleanedPosition += carriedCount;
                rawPosition = replacement.Range.Start;
            }
            var rawText = string.Concat(characters.Skip(replacement.Range.Start).Take(replacement.Range.Length));
            var replacementCount = new TextIndexMap(replacement.Text).GraphemeCount;
            var cleanedRange = new TextRange(cleanedPosition, replacementCount);
            cleaned.Append(replacement.Text);
            segments.Add(new EditMapSegment(replacement.Range, cleanedRange, true));
            edits.Add(new TextEdit(replacement.Kind, replacement.Range, cleanedRange, rawText, replacement.Text));
            cleanedPosition += replacementCount;
            rawPosition = replacement.Range.End;
        }
        if (rawPosition < characters.Count)
        {
            var carried = string.Concat(characters.Skip(rawPosition));
            cleaned.Append(carried);
            segments.Add(new EditMapSegment(new TextRange(rawPosition, characters.Count - rawPosition), new TextRange(cleanedPosition, characters.Count - rawPosition), false));
            cleanedPosition += characters.Count - rawPosition;
        }
        return new CleanupResult(raw, cleaned.ToString(), edits, new EditMap(segments, characters.Count, cleanedPosition), language);
    }

    private static bool Overlaps(TextRange left, TextRange right) =>
        left == right || (left.Start < right.End && right.Start < left.End);
}
