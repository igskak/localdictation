using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;
using Witness.Core.Review;
using Witness.Core.Text;

namespace Witness.Core.Tests;

[TestClass]
public sealed class ReviewAudioLeaseTests
{
    [TestMethod]
    public void QuietResultClearsCompletedAudioImmediately()
    {
        var audio = Enumerable.Repeat(0.5f, 32).ToArray();
        using var lease = new ReviewAudioLease();

        Assert.IsFalse(lease.Replace(audio, 16_000, Result(ReviewDecision.Quiet)));
        Assert.IsFalse(lease.HasAudio);
        Assert.IsTrue(audio.All(sample => sample == 0));
    }

    [TestMethod]
    public void AttentionRetainsOnlyUntilReplacementOrRelease()
    {
        var first = Enumerable.Repeat(0.25f, 32).ToArray();
        var second = Enumerable.Repeat(0.75f, 32).ToArray();
        using var lease = new ReviewAudioLease();

        Assert.IsTrue(lease.Replace(first, 16_000, Result(Attention())));
        Assert.AreEqual(32, lease.FrameCount);
        Assert.IsTrue(lease.Replace(second, 16_000, Result(Attention())));
        Assert.IsTrue(first.All(sample => sample == 0));
        Assert.IsTrue(second.Any(sample => sample != 0));

        lease.Release();
        Assert.IsTrue(second.All(sample => sample == 0));
        Assert.IsFalse(lease.HasAudio);
    }

    [TestMethod]
    public void ReplayCopiesOnlyFlaggedTimedSpanWithBoundedPadding()
    {
        var audio = Enumerable.Range(0, 100).Select(value => (float)value).ToArray();
        var flagged = Span(0.8, 0.30, 0.50);
        var displayOnly = Span(0.6, 0.60, 0.70);
        var decision = new ReviewDecision(true, [flagged], [flagged, displayOnly]);
        using var lease = new ReviewAudioLease();
        Assert.IsTrue(lease.Replace(audio, 100, Result(decision)));

        Assert.IsTrue(lease.TryCopyFlaggedFragment(flagged, out var fragment, paddingSeconds: 0.1));
        CollectionAssert.AreEqual(
            Enumerable.Range(20, 40).Select(value => (float)value).ToArray(),
            fragment);
        Assert.IsFalse(lease.TryCopyFlaggedFragment(displayOnly, out _));
        Assert.IsFalse(lease.TryCopyFlaggedFragment(Span(0.8, null, null), out _));
    }

    [TestMethod]
    public void DisposalClearsOwnedAudioAndRejectsReuse()
    {
        var audio = Enumerable.Repeat(1f, 8).ToArray();
        var lease = new ReviewAudioLease();
        Assert.IsTrue(lease.Replace(audio, 16_000, Result(Attention())));

        lease.Dispose();

        Assert.IsTrue(audio.All(sample => sample == 0));
        Assert.ThrowsExactly<ObjectDisposedException>(() =>
            lease.Replace([1f], 16_000, Result(Attention())));
    }

    private static ProcessedDictation Result(ReviewDecision decision)
    {
        var language = SpeechLanguage.English;
        var cleanup = CleanupResult.Unchanged("synthetic", language);
        return new ProcessedDictation(
            cleanup.Raw,
            cleanup,
            decision.Highlighted,
            decision,
            language,
            new LanguageProfile(language));
    }

    private static ReviewDecision Attention()
    {
        var span = Span(0.8, 0, 0.001);
        return new ReviewDecision(true, [span], [span]);
    }

    private static RiskSpan Span(double weight, double? start, double? end) => new(
        RiskReasonKind.Number,
        new TextRange(0, 1),
        new TextRange(0, 1),
        weight,
        "1",
        start,
        end);
}
