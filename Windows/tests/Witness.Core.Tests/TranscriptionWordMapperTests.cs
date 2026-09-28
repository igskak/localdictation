using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Text;
using Witness.Core.Transcription;

namespace Witness.Core.Tests;

[TestClass]
public sealed class TranscriptionWordMapperTests
{
    [TestMethod]
    public void RepeatedWordsKeepDistinctSequentialGraphemeRanges()
    {
        var mapped = TranscriptionWordMapper.Map([
            Segment(" test test", 0, 900),
        ]);

        Assert.HasCount(2, mapped.Words);
        Assert.AreEqual(new TextRange(1, 4), mapped.Words[0].GraphemeRange);
        Assert.AreEqual(new TextRange(6, 4), mapped.Words[1].GraphemeRange);
        Assert.AreEqual("test", new TextIndexMap(mapped.Text).Slice(mapped.Words[1].GraphemeRange));
    }

    [TestMethod]
    public void UnicodeWordsUseGraphemesRatherThanUtf16CodeUnits()
    {
        var mapped = TranscriptionWordMapper.Map([
            Segment(" 👍🏽 їжа e\u0301lan", 100, 1200),
        ]);

        Assert.HasCount(2, mapped.Words);
        CollectionAssert.AreEqual(
            new[] { "їжа", "e\u0301lan" },
            mapped.Words.Select(word => word.Text).ToArray());
        Assert.AreEqual(new TextRange(3, 3), mapped.Words[0].GraphemeRange);
        Assert.AreEqual(new TextRange(7, 4), mapped.Words[1].GraphemeRange);
    }

    [TestMethod]
    public void ExactTokenCoverageProvidesTokenTimingAndProbability()
    {
        var segment = new TranscriptionSegment(
            " hello",
            TimeSpan.Zero,
            TimeSpan.FromSeconds(1),
            [
                new TranscriptionToken(" hel", 0.8F, TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(500)),
                new TranscriptionToken("lo", 0.6F, TimeSpan.FromMilliseconds(500), TimeSpan.FromMilliseconds(800)),
            ]);

        var mapped = TranscriptionWordMapper.Map([segment]);

        Assert.HasCount(1, mapped.Words);
        var word = mapped.Words[0];
        Assert.AreEqual(TranscriptionTimingGranularity.Token, word.TimingGranularity);
        Assert.AreEqual(TimeSpan.FromMilliseconds(100), word.Start);
        Assert.AreEqual(TimeSpan.FromMilliseconds(800), word.End);
        Assert.AreEqual(0.7F, word.MeanTokenProbability!.Value, 0.0001F);
        Assert.AreEqual(TranscriptionTimingGranularity.Token, mapped.TimingGranularity);
    }

    [TestMethod]
    public void MissingTokenTimingFallsBackToHonestSegmentRange()
    {
        var segment = new TranscriptionSegment(
            " hello world",
            TimeSpan.FromMilliseconds(200),
            TimeSpan.FromMilliseconds(1200),
            [
                new TranscriptionToken(" hello", 0.9F),
                new TranscriptionToken(" world", 0.8F),
            ]);

        var mapped = TranscriptionWordMapper.Map([segment]);

        Assert.IsTrue(mapped.Words.All(word => word.TimingGranularity == TranscriptionTimingGranularity.Segment));
        Assert.IsTrue(mapped.Words.All(word => word.Start == segment.Start && word.End == segment.End));
        Assert.AreEqual(TranscriptionTimingGranularity.Segment, mapped.TimingGranularity);
    }

    [TestMethod]
    public void TokenTextMismatchFallsBackWithoutGuessingOffsets()
    {
        var segment = new TranscriptionSegment(
            " actual words",
            TimeSpan.Zero,
            TimeSpan.FromSeconds(2),
            [new TranscriptionToken(" different tokens", 0.9F, TimeSpan.Zero, TimeSpan.FromSeconds(1))]);

        var mapped = TranscriptionWordMapper.Map([segment]);

        Assert.HasCount(2, mapped.Words);
        Assert.IsTrue(mapped.Words.All(word => word.MeanTokenProbability is null));
        Assert.IsTrue(mapped.Words.All(word => word.TimingGranularity == TranscriptionTimingGranularity.Segment));
    }

    [TestMethod]
    public void SegmentRangesAccumulateAcrossTranscriptWithoutSearching()
    {
        var mapped = TranscriptionWordMapper.Map([
            Segment(" one", 0, 500),
            Segment(" one", 500, 1000),
        ]);

        Assert.HasCount(2, mapped.Words);
        Assert.AreEqual(new TextRange(1, 3), mapped.Words[0].GraphemeRange);
        Assert.AreEqual(new TextRange(5, 3), mapped.Words[1].GraphemeRange);
        Assert.AreEqual(0, mapped.Words[0].SegmentIndex);
        Assert.AreEqual(1, mapped.Words[1].SegmentIndex);
    }

    private static TranscriptionSegment Segment(string text, int startMs, int endMs) => new(
        text,
        TimeSpan.FromMilliseconds(startMs),
        TimeSpan.FromMilliseconds(endMs),
        []);
}
