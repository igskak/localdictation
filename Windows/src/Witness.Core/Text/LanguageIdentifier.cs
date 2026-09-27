using System.Text;
using Witness.Core.Languages;

namespace Witness.Core.Text;

public enum TextScript
{
    Latin,
    Cyrillic,
    Neutral,
}

/// <summary>
/// Deterministic per-word evidence, not a general language classifier.
/// Unknown or mixed evidence deliberately returns no language.
/// </summary>
public static class LanguageIdentifier
{
    private static readonly HashSet<Rune> RussianExclusive = Runes("ыъэё");
    private static readonly HashSet<Rune> UkrainianExclusive = Runes("іїєґ");
    private static readonly HashSet<Rune> GermanExclusive = Runes("äöüß");

    public static TextScript Script(string word)
    {
        ArgumentNullException.ThrowIfNull(word);
        var sawLatin = false;
        var sawCyrillic = false;
        foreach (var rune in word.ToLowerInvariant().EnumerateRunes())
        {
            if (!Rune.IsLetter(rune)) continue;
            if (rune.Value is >= 0x0041 and <= 0x005A
                or >= 0x0061 and <= 0x007A
                or >= 0x00C0 and <= 0x024F)
            {
                sawLatin = true;
            }
            else if (rune.Value is >= 0x0400 and <= 0x04FF or >= 0x0500 and <= 0x052F)
            {
                sawCyrillic = true;
            }
        }

        return (sawLatin, sawCyrillic) switch
        {
            (true, false) => TextScript.Latin,
            (false, true) => TextScript.Cyrillic,
            _ => TextScript.Neutral,
        };
    }

    public static SpeechLanguage? Language(string word)
    {
        ArgumentNullException.ThrowIfNull(word);
        var runes = word.ToLowerInvariant().EnumerateRunes().ToArray();
        return Script(word) switch
        {
            TextScript.Cyrillic => ExclusiveCyrillicLanguage(runes),
            TextScript.Latin when runes.Any(GermanExclusive.Contains) => SpeechLanguage.German,
            _ => null,
        };
    }

    public static bool ScriptMatches(string word, LanguageProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var script = Script(word);
        if (script == TextScript.Neutral) return true;
        return profile.Languages.Any(language => language.Script switch
        {
            LanguageScript.Latin => script == TextScript.Latin,
            LanguageScript.Cyrillic => script == TextScript.Cyrillic,
            LanguageScript.Other => true,
            _ => false,
        });
    }

    private static SpeechLanguage? ExclusiveCyrillicLanguage(IEnumerable<Rune> runes)
    {
        var materialized = runes.ToArray();
        var russian = materialized.Any(RussianExclusive.Contains);
        var ukrainian = materialized.Any(UkrainianExclusive.Contains);
        if (russian == ukrainian) return null;
        return russian ? SpeechLanguage.Russian : SpeechLanguage.Ukrainian;
    }

    private static HashSet<Rune> Runes(string value) => value.EnumerateRunes().ToHashSet();
}
