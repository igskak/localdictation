using Witness.Core.Languages;
using Witness.Core.Text;

namespace Witness.Core.Review;

public enum SessionGlossaryAddResult
{
    Added,
    Empty,
    TooLong,
    Duplicate,
    Full,
    LanguageNotSelected,
}

/// <summary>
/// User vocabulary for the current process only. This type has no persistence
/// surface by design: Windows vocabulary is released when the app exits.
/// </summary>
public sealed class SessionGlossary
{
    public const int MaximumEntries = 500;
    public const int MaximumTermGraphemes = 80;
    private readonly List<GlossaryEntry> entries = [];

    public IReadOnlyList<GlossaryEntry> Entries => entries.ToArray();

    public SessionGlossaryAddResult Add(
        string term,
        SpeechLanguage language,
        LanguageProfile selectedProfile)
    {
        ArgumentNullException.ThrowIfNull(term);
        ArgumentNullException.ThrowIfNull(selectedProfile);
        if (!selectedProfile.Contains(language))
        {
            return SessionGlossaryAddResult.LanguageNotSelected;
        }

        var normalized = term.Trim();
        if (normalized.Length == 0)
        {
            return SessionGlossaryAddResult.Empty;
        }
        if (new TextIndexMap(normalized).GraphemeCount > MaximumTermGraphemes)
        {
            return SessionGlossaryAddResult.TooLong;
        }
        if (entries.Any(entry => entry.Language == language
            && string.Equals(entry.Term, normalized, StringComparison.OrdinalIgnoreCase)))
        {
            return SessionGlossaryAddResult.Duplicate;
        }
        if (entries.Count >= MaximumEntries)
        {
            return SessionGlossaryAddResult.Full;
        }

        entries.Add(new GlossaryEntry(normalized, language));
        return SessionGlossaryAddResult.Added;
    }

    public bool Remove(string term, SpeechLanguage language)
    {
        var index = entries.FindIndex(entry => entry.Language == language
            && string.Equals(entry.Term, term, StringComparison.Ordinal));
        if (index < 0)
        {
            return false;
        }
        entries.RemoveAt(index);
        return true;
    }

    public void Clear() => entries.Clear();
}
