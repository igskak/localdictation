using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;
using Witness.Core.Review;
using Witness.Core.Text;
using Witness.Core.Transcription;

namespace Witness.Core.Tests;

[TestClass]
public sealed class DictationPostProcessorTests
{
    [TestMethod]
    public void VerifiedTranscriptProducesCleanedInsertionAndTimedReviewEvidence()
    {
        var raw = "ähm bitte überweise 1450 euro";
        var transcript = new MappedTranscript(
            raw,
            [
                Word("ähm", raw, 0, 0.0, 0.2),
                Word("bitte", raw, 1, 0.2, 0.4),
                Word("überweise", raw, 2, 0.4, 0.7),
                Word("1450", raw, 3, 0.7, 0.9),
                Word("euro", raw, 4, 0.9, 1.1),
            ],
            TranscriptionTimingGranularity.Token);

        var result = new DictationPostProcessor().Process(
            transcript,
            SpeechLanguage.German,
            new LanguageProfile(SpeechLanguage.German));

        Assert.AreEqual(raw, result.RawText);
        Assert.AreEqual("Bitte überweise 1450 euro.", result.TextForInsertion);
        Assert.IsTrue(result.Review.DeservesAttention);
        Assert.IsTrue(result.Review.Flagged.Any(span => span.Text == "1450"));
        Assert.IsTrue(result.Review.Highlighted.Any(span => span.Reason == RiskReasonKind.CleanupEdit));
        Assert.IsTrue(result.RetainAudioForReview);
        var number = result.Review.Flagged.Single(span => span.Text == "1450");
        Assert.AreEqual(0.7, number.StartSeconds);
        Assert.AreEqual(0.9, number.EndSeconds);
    }

    [TestMethod]
    public void QuietResultDoesNotRetainAudio()
    {
        var raw = "please send the invoice";
        var result = new DictationPostProcessor().Process(
            new MappedTranscript(
                raw,
                [Word("please", raw, 0, 0, 0.2)],
                TranscriptionTimingGranularity.Segment),
            SpeechLanguage.English,
            new LanguageProfile(SpeechLanguage.English));

        Assert.IsFalse(result.Review.DeservesAttention);
        Assert.IsFalse(result.Review.HasAnythingToShow);
        Assert.IsFalse(result.RetainAudioForReview);
    }

    [TestMethod]
    public void DisplayOnlyReviewDoesNotExtendAudioLifetime()
    {
        var raw = "Please ask Miller tomorrow";
        var result = new DictationPostProcessor().Process(
            new MappedTranscript(
                raw,
                [Word("Miller", raw, 2, 0.3, 0.6)],
                TranscriptionTimingGranularity.Token),
            SpeechLanguage.English,
            new LanguageProfile(SpeechLanguage.English));

        Assert.IsFalse(result.Review.DeservesAttention);
        Assert.IsTrue(result.Review.HasAnythingToShow);
        Assert.IsFalse(result.RetainAudioForReview);
    }

    [TestMethod]
    public void UnverifiedLanguageLeavesTextUnchangedAndKeepsCalibratedSignalsOff()
    {
        Assert.IsTrue(SpeechLanguage.TryCreate("pl", out var polish));
        var raw = "  proszę   wysłać  ";
        var result = new DictationPostProcessor().Process(
            new MappedTranscript(raw, [], TranscriptionTimingGranularity.Segment),
            polish,
            new LanguageProfile(polish));

        Assert.AreEqual(raw, result.TextForInsertion);
        Assert.HasCount(0, result.Risks);
        Assert.AreEqual(ReviewDecision.Quiet, result.Review);
    }

    [TestMethod]
    public void GlossaryNearMissUsesSelectedProfileAndKeepsRawRecoveryText()
    {
        var raw = "Bitte an Miller überweisen";
        var result = new DictationPostProcessor().Process(
            new MappedTranscript(
                raw,
                [Word("Miller", raw, 2, 0.3, 0.6)],
                TranscriptionTimingGranularity.Token),
            SpeechLanguage.German,
            new LanguageProfile(SpeechLanguage.German),
            [new GlossaryEntry("Müller", SpeechLanguage.German)]);

        Assert.AreEqual(raw, result.RawText);
        var nearMiss = result.Review.Flagged.Single(span => span.Reason == RiskReasonKind.Glossary);
        Assert.AreEqual("Miller", nearMiss.Text);
        Assert.AreEqual("Müller", nearMiss.Detail);
        Assert.IsTrue(nearMiss.IsPlayable);
    }

    [TestMethod]
    public void FinalLanguageOutsideSelectedProfileIsRejected()
    {
        var transcript = new MappedTranscript("synthetic", [], TranscriptionTimingGranularity.Segment);
        Assert.ThrowsExactly<ArgumentException>(() => new DictationPostProcessor().Process(
            transcript,
            SpeechLanguage.German,
            new LanguageProfile(SpeechLanguage.English)));
    }

    private static TranscriptionWord Word(
        string text,
        string raw,
        int occurrence,
        double start,
        double end)
    {
        var words = WordScanner.Words(raw);
        var match = words[occurrence];
        Assert.AreEqual(text, match.Text);
        return new TranscriptionWord(
            text,
            match.Range,
            TimeSpan.FromSeconds(start),
            TimeSpan.FromSeconds(end),
            0.9f,
            TranscriptionTimingGranularity.Token,
            0);
    }
}
