using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Audio;
using Witness.Core.Input;
using Witness.Core.Languages;
using Witness.Core.Review;
using Witness.Core.Settings;

namespace Witness.Core.Tests;

[TestClass]
public sealed class SettingsAndGlossaryTests
{
    [TestMethod]
    public void PreferencesNormalizeUnknownAndDuplicateLanguagesWithoutContentFields()
    {
        var preferences = new UserPreferences(
            true,
            ["uk", "unknown", "uk", "en"],
            HotkeyActivationMode.Toggle,
            AudioInputSelection.Specific("synthetic-device"));

        var normalized = preferences.Normalized();

        CollectionAssert.AreEqual(new[] { "uk", "en" }, normalized.LanguageCodes.ToArray());
        Assert.AreEqual("uk+en", normalized.LanguageProfile().Id);
        Assert.AreEqual(HotkeyActivationMode.Toggle, normalized.ActivationMode);
        Assert.AreEqual("synthetic-device", normalized.AudioInput.DeviceId);
        Assert.IsFalse(typeof(UserPreferences).GetProperties().Any(property =>
            property.Name.Contains("Transcript", StringComparison.OrdinalIgnoreCase)
            || property.Name.Contains("Glossary", StringComparison.OrdinalIgnoreCase)
            || property.Name.Contains("History", StringComparison.OrdinalIgnoreCase)));
    }

    [TestMethod]
    public void EmptyLanguageSelectionFallsBackToTheExplicitDefault()
    {
        var normalized = UserPreferences.Default with { LanguageCodes = [] };
        CollectionAssert.AreEqual(new[] { "de", "en" }, normalized.Normalized().LanguageCodes.ToArray());
    }

    [TestMethod]
    public void SessionGlossaryIsScopedDeduplicatedAndRemovable()
    {
        var glossary = new SessionGlossary();
        var profile = new LanguageProfile(SpeechLanguage.German, SpeechLanguage.English);

        Assert.AreEqual(SessionGlossaryAddResult.Added, glossary.Add(" Müller ", SpeechLanguage.German, profile));
        Assert.AreEqual(SessionGlossaryAddResult.Duplicate, glossary.Add("müller", SpeechLanguage.German, profile));
        Assert.AreEqual(SessionGlossaryAddResult.Added, glossary.Add("Müller", SpeechLanguage.English, profile));
        Assert.AreEqual(SessionGlossaryAddResult.LanguageNotSelected, glossary.Add("Мюллер", SpeechLanguage.Russian, profile));
        Assert.HasCount(2, glossary.Entries);
        Assert.IsTrue(glossary.Remove("Müller", SpeechLanguage.German));
        Assert.HasCount(1, glossary.Entries);
    }

    [TestMethod]
    public void SessionGlossaryRejectsEmptyAndOverlongTerms()
    {
        var glossary = new SessionGlossary();
        var profile = new LanguageProfile(SpeechLanguage.English);

        Assert.AreEqual(SessionGlossaryAddResult.Empty, glossary.Add("  ", SpeechLanguage.English, profile));
        Assert.AreEqual(
            SessionGlossaryAddResult.TooLong,
            glossary.Add(new string('a', SessionGlossary.MaximumTermGraphemes + 1), SpeechLanguage.English, profile));
    }
}
