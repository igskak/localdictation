using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Audio;
using Witness.Core.History;
using Witness.Core.Languages;
using Witness.Core.Review;
using Witness.Core.Text;

namespace Witness.Core.Tests;

[TestClass]
public sealed class W8SoakPolicyTests
{
    [TestMethod]
    public void RepeatedSyntheticSessionsStayWithinAudioAndHistoryBounds()
    {
        const int iterations = 5_000;
        var buffer = new BoundedPcmBuffer(capacityFrames: 32);
        var history = new RecentDictationHistory();
        using var reviewAudio = new ReviewAudioLease();
        float[]? previouslyLeased = null;
        var startedAt = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

        for (var index = 0; index < iterations; index++)
        {
            var capture = Enumerable.Repeat((index % 7 + 1) / 10F, 48).ToArray();
            var append = buffer.Append(capture);
            Assert.AreEqual(32, append.AcceptedFrames);
            Assert.AreEqual(16, append.DroppedFrames);
            Assert.AreEqual(buffer.CapacityFrames, buffer.FrameCount);

            var completedAudio = buffer.MakeSamples();
            buffer.Reset();
            Assert.AreEqual(0, buffer.FrameCount);

            var requiresReview = index % 3 == 0;
            var retained = reviewAudio.Replace(
                completedAudio,
                completedSampleRate: 16_000,
                Result(requiresReview ? Attention() : ReviewDecision.Quiet));

            if (previouslyLeased is not null)
            {
                Assert.IsTrue(previouslyLeased.All(sample => sample == 0));
            }
            Assert.AreEqual(requiresReview, retained);
            Assert.IsLessThanOrEqualTo(32, reviewAudio.FrameCount);
            if (requiresReview)
            {
                previouslyLeased = completedAudio;
            }
            else
            {
                Assert.IsTrue(completedAudio.All(sample => sample == 0));
                previouslyLeased = null;
            }

            Assert.IsTrue(history.Add($"synthetic qa phrase {index}", startedAt.AddSeconds(index)));
            Assert.IsLessThanOrEqualTo(RecentDictationHistory.MaximumCount, history.Items.Count);
        }

        reviewAudio.Release();
        if (previouslyLeased is not null)
        {
            Assert.IsTrue(previouslyLeased.All(sample => sample == 0));
        }
        Assert.IsFalse(reviewAudio.HasAudio);
        Assert.HasCount(RecentDictationHistory.MaximumCount, history.Items);
        Assert.AreEqual($"synthetic qa phrase {iterations - 1}", history.Items[0].Text);
        Assert.AreEqual($"synthetic qa phrase {iterations - RecentDictationHistory.MaximumCount}", history.Items[^1].Text);
    }

    private static ProcessedDictation Result(ReviewDecision decision)
    {
        var cleanup = CleanupResult.Unchanged("synthetic", SpeechLanguage.English);
        return new ProcessedDictation(
            cleanup.Raw,
            cleanup,
            decision.Highlighted,
            decision,
            SpeechLanguage.English,
            new LanguageProfile(SpeechLanguage.English));
    }

    private static ReviewDecision Attention()
    {
        var span = new RiskSpan(
            RiskReasonKind.Number,
            new TextRange(0, 1),
            new TextRange(0, 1),
            0.8,
            "1",
            StartSeconds: 0,
            EndSeconds: 0.001);
        return new ReviewDecision(true, [span], [span]);
    }
}
