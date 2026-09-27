using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;

namespace Witness.Core.Tests;

[TestClass]
public sealed class LanguagePolicyTests
{
    [TestMethod]
    public void CatalogMatchesWhisperCodesAndVerifiedTier()
    {
        Assert.HasCount(100, LanguageCatalog.All);
        Assert.HasCount(100, LanguageCatalog.ByCode);
        CollectionAssert.AreEquivalent(new[] { "de", "en", "ru", "uk" }, LanguageCatalog.VerifiedCodes.ToArray());
        Assert.IsTrue(LanguageCatalog.ByCode.ContainsKey("jw"));
        Assert.IsTrue(LanguageCatalog.ByCode.ContainsKey("yue"));
        Assert.IsFalse(LanguageCatalog.ByCode.ContainsKey("jv"));
        Assert.IsFalse(LanguageCatalog.ByCode.ContainsKey("cmn"));
    }

    [TestMethod]
    public void OneSelectedLanguageIsNeverDetected()
    {
        var decision = LanguageDecision.Choose(new LanguageProfile(SpeechLanguage.German), new Dictionary<string, float> { ["ru"] = 0.99F });
        Assert.AreEqual(SpeechLanguage.German, decision.Language);
        Assert.AreEqual(LanguageDecisionReason.OnlyLanguage, decision.Reason);
    }

    [TestMethod]
    public void ClearLeaderWinsInsideSelectedSetOnly()
    {
        var profile = new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.English, SpeechLanguage.Ukrainian);
        var decision = LanguageDecision.Choose(profile, new Dictionary<string, float>
        {
            ["pl"] = 0.99F,
            ["ru"] = 0.1F,
            ["en"] = 0.85F,
            ["uk"] = 0.05F,
        });
        Assert.AreEqual(SpeechLanguage.English, decision.Language);
        Assert.AreEqual(LanguageDecisionReason.Confident, decision.Reason);
    }

    [TestMethod]
    public void NoEvidenceFallsBackToPreferredLanguage()
    {
        var profile = new LanguageProfile(SpeechLanguage.Ukrainian, SpeechLanguage.English);
        var decision = LanguageDecision.Choose(profile, new Dictionary<string, float> { ["pl"] = 0.6F, ["cs"] = 0.3F });
        Assert.AreEqual(SpeechLanguage.Ukrainian, decision.Language);
        Assert.AreEqual(LanguageDecisionReason.NoEvidence, decision.Reason);
    }

    [TestMethod]
    public void AmbiguousUtteranceContinuesPreviousContender()
    {
        var profile = new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.English, SpeechLanguage.Ukrainian);
        var decision = LanguageDecision.Choose(
            profile,
            new Dictionary<string, float> { ["ru"] = 0.44F, ["uk"] = 0.40F, ["en"] = 0.02F },
            SpeechLanguage.Ukrainian);
        Assert.AreEqual(SpeechLanguage.Ukrainian, decision.Language);
        Assert.AreEqual(LanguageDecisionReason.ContinuedFromPrevious, decision.Reason);
    }

    [TestMethod]
    public void ConfidentUtteranceIsNotOverruledByPreviousLanguage()
    {
        var decision = LanguageDecision.Choose(
            new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.Ukrainian),
            new Dictionary<string, float> { ["ru"] = 0.05F, ["uk"] = 0.92F },
            SpeechLanguage.Russian);
        Assert.AreEqual(SpeechLanguage.Ukrainian, decision.Language);
        Assert.AreEqual(LanguageDecisionReason.Confident, decision.Reason);
    }

    [TestMethod]
    public void PreferredLanguageIsTieBreakNotVeto()
    {
        var decision = LanguageDecision.Choose(
            new LanguageProfile(SpeechLanguage.English, SpeechLanguage.Russian, SpeechLanguage.Ukrainian),
            new Dictionary<string, float> { ["ru"] = 0.46F, ["uk"] = 0.43F, ["en"] = 0.01F });
        Assert.AreEqual(SpeechLanguage.Russian, decision.Language);
        Assert.AreEqual(LanguageDecisionReason.LeadWithoutMargin, decision.Reason);
    }

    [TestMethod]
    public void ExactTieUsesProfileOrderDeterministically()
    {
        var probabilities = new Dictionary<string, float> { ["ru"] = 0.5F, ["uk"] = 0.5F };
        Assert.AreEqual(SpeechLanguage.Ukrainian, LanguageDecision.Choose(new LanguageProfile(SpeechLanguage.Ukrainian, SpeechLanguage.Russian), probabilities).Language);
        Assert.AreEqual(SpeechLanguage.Russian, LanguageDecision.Choose(new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.Ukrainian), probabilities).Language);
    }

    [TestMethod]
    public void PinNarrowsOnlyInsideSelectedSetAndIsNotAProfileMutation()
    {
        var profile = new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.English, SpeechLanguage.Ukrainian);
        var pinned = profile.EffectiveForPin(SpeechLanguage.Ukrainian);
        Assert.AreEqual("uk", pinned.Id);
        Assert.IsFalse(pinned.IsMixed);
        Assert.AreEqual("ru+en+uk", profile.Id);
        Assert.AreSame(profile, profile.EffectiveForPin(SpeechLanguage.German));
    }

    [TestMethod]
    public void PreviousLanguageExpiresAfterOneHundredTwentySeconds()
    {
        var continuity = new LanguageContinuity();
        var start = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        continuity.Observe(SpeechLanguage.Ukrainian, start);
        Assert.AreEqual(SpeechLanguage.Ukrainian, continuity.PreviousAt(start.AddSeconds(120)));
        Assert.IsNull(continuity.PreviousAt(start.AddSeconds(121)));
        Assert.IsNull(continuity.PreviousAt(start.AddSeconds(-1)));
    }

    [TestMethod]
    public void EngineLanguageMustBeChosenAfterCompletedRecordingNotPrefix()
    {
        var policy = new LanguageDetectionTimingPolicy();
        Assert.IsFalse(policy.CanCommitFinalLanguage(recordingCompleted: false));
        Assert.IsTrue(policy.CanCommitFinalLanguage(recordingCompleted: true));
    }
}
