using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.History;
using Witness.Core.Languages;
using Witness.Core.Review;
using Witness.Core.Text;

namespace Witness.Core.Tests;

[TestClass]
public sealed class ReviewAndHistoryPolicyTests
{
    [TestMethod]
    public void AttentionAndDisplayThresholdsRemainSeparate()
    {
        var spans = new[] { Span(0.05), Span(0.3), Span(0.8) };
        var decision = ReviewCoordinator.Decide(spans);
        Assert.IsTrue(decision.DeservesAttention);
        Assert.HasCount(1, decision.Flagged);
        Assert.HasCount(2, decision.Highlighted);
        Assert.IsTrue(decision.Highlighted.Contains(decision.Flagged[0]));
    }

    [TestMethod]
    public void NamedEntityAloneCanBeShownWithoutDemandingAttention()
    {
        var decision = ReviewCoordinator.Decide([Span(0.6, RiskReasonKind.NamedEntity)]);
        Assert.IsFalse(decision.DeservesAttention);
        Assert.HasCount(1, decision.Highlighted);
    }

    [TestMethod]
    public void ManyLightSignalsNeverAccumulateIntoAttention()
    {
        var decision = ReviewCoordinator.Decide(Enumerable.Range(0, 20).Select(_ => Span(0.05, RiskReasonKind.CleanupEdit)));
        Assert.IsFalse(decision.DeservesAttention);
        Assert.HasCount(0, decision.Highlighted);
    }

    [TestMethod]
    public void EmptyResultIsAlwaysQuiet()
    {
        Assert.AreEqual(ReviewDecision.Quiet, ReviewCoordinator.Decide([Span(0.9)], isEmptyResult: true));
    }

    [TestMethod]
    public void DisplayThresholdCannotHideAttentionCause()
    {
        var policy = new ReviewPolicy(0.5, 0.9);
        Assert.AreEqual(0.5, policy.DisplayThreshold);
    }

    [TestMethod]
    public void ConfidenceHasZeroWeightUntilMeasured()
    {
        Assert.AreEqual(0D, RiskPolicy.ModelConfidenceWeight);
    }

    [TestMethod]
    public void UnverifiedLanguagesDoNotEnableLanguageSpecificGuessing()
    {
        Assert.IsTrue(SpeechLanguage.TryCreate("pl", out var polish));
        Assert.IsFalse(RiskPolicy.CanUseLanguageSpecificSignal(polish, RiskReasonKind.MalformedWord));
        Assert.IsTrue(RiskPolicy.CanUseLanguageSpecificSignal(polish, RiskReasonKind.Number));
        Assert.IsTrue(RiskPolicy.CanUseLanguageSpecificSignal(SpeechLanguage.Ukrainian, RiskReasonKind.MalformedWord));
    }

    [TestMethod]
    public void HistoryKeepsLatestTenNonEmptyTextsOnlyInMemoryPolicy()
    {
        var history = new RecentDictationHistory();
        var start = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        Assert.IsFalse(history.Add("", start));
        Assert.IsFalse(history.Add("secret", start, insertionRefusedForProtectedField: true));
        for (var index = 0; index < 12; index++)
        {
            Assert.IsTrue(history.Add($"synthetic {index}", start.AddSeconds(index)));
        }
        Assert.HasCount(10, history.Items);
        Assert.AreEqual("synthetic 11", history.Items[0].Text);
        Assert.AreEqual("synthetic 2", history.Items[^1].Text);
        history.Clear();
        Assert.HasCount(0, history.Items);
    }

    private static RiskSpan Span(double weight, RiskReasonKind reason = RiskReasonKind.Number) =>
        new(reason, new TextRange(0, 4), new TextRange(0, 4), weight, "1450", 0, 0.5);
}
