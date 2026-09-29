using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;
using Witness.Platform.Windows.Review;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class WindowsSpellCheckingLexiconTests
{
    [TestMethod]
    public void VerifiedLanguageUsesFirstInstalledSpecificDictionaryAndCachesCapability()
    {
        var native = new FakeNative { SupportedTag = "de-CH", Known = false };
        var lexicon = new WindowsSpellCheckingLexicon(native);

        Assert.IsTrue(lexicon.Supports(SpeechLanguage.German));
        Assert.IsTrue(lexicon.Supports(SpeechLanguage.German));
        Assert.IsFalse(lexicon.IsKnownWord("synthetisch", SpeechLanguage.German));
        Assert.AreEqual(1, native.ResolveCalls);
        CollectionAssert.AreEqual(
            new[] { "de-DE", "de-AT", "de-CH" },
            native.Candidates!.ToArray());
        Assert.AreEqual("de-CH", native.CheckedTag);
    }

    [TestMethod]
    public void MissingDictionaryDisablesCapabilityInsteadOfGuessing()
    {
        var native = new FakeNative();
        var lexicon = new WindowsSpellCheckingLexicon(native);

        Assert.IsFalse(lexicon.Supports(SpeechLanguage.Ukrainian));
        Assert.IsTrue(lexicon.IsKnownWord("пперевірка", SpeechLanguage.Ukrainian));
        Assert.AreEqual(0, native.CheckCalls);
    }

    [TestMethod]
    public void CheckFailureTreatsWordAsKnownToAvoidFalseWarning()
    {
        var native = new FakeNative { SupportedTag = "en-GB", CheckSucceeds = false };
        var lexicon = new WindowsSpellCheckingLexicon(native);

        Assert.IsTrue(lexicon.Supports(SpeechLanguage.English));
        Assert.IsTrue(lexicon.IsKnownWord("synthetic", SpeechLanguage.English));
    }

    [TestMethod]
    public void UnverifiedLanguageNeverQueriesWindowsDictionary()
    {
        Assert.IsTrue(SpeechLanguage.TryCreate("pl", out var polish));
        var native = new FakeNative { SupportedTag = "pl-PL" };
        var lexicon = new WindowsSpellCheckingLexicon(native);

        Assert.IsFalse(lexicon.Supports(polish));
        Assert.IsTrue(lexicon.IsKnownWord("syntetyczny", polish));
        Assert.AreEqual(0, native.ResolveCalls);
        Assert.AreEqual(0, native.CheckCalls);
    }

    private sealed class FakeNative : IWindowsSpellCheckNative
    {
        public string? SupportedTag { get; init; }
        public bool CheckSucceeds { get; init; } = true;
        public bool Known { get; init; } = true;
        public int ResolveCalls { get; private set; }
        public int CheckCalls { get; private set; }
        public IReadOnlyList<string>? Candidates { get; private set; }
        public string? CheckedTag { get; private set; }

        public bool TryResolveLanguageTag(IReadOnlyList<string> candidates, out string languageTag)
        {
            ResolveCalls++;
            Candidates = candidates;
            languageTag = SupportedTag ?? string.Empty;
            return SupportedTag is not null && candidates.Contains(SupportedTag);
        }

        public bool TryIsKnownWord(string languageTag, string word, out bool isKnown)
        {
            CheckCalls++;
            CheckedTag = languageTag;
            isKnown = Known;
            return CheckSucceeds;
        }
    }
}
