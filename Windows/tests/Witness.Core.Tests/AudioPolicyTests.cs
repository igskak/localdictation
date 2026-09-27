using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Audio;

namespace Witness.Core.Tests;

[TestClass]
public sealed class AudioPolicyTests
{
    [TestMethod]
    public void BoundedBufferNeverGrowsAndReportsDroppedFrames()
    {
        var buffer = new BoundedPcmBuffer(4);
        var input = new[] { -0.2F, 0.4F, -0.8F, 0.1F, 1.0F, 0.5F };

        var result = buffer.Append(input);

        Assert.AreEqual(new BufferAppendResult(4, 2), result);
        Assert.AreEqual(4, buffer.FrameCount);
        Assert.AreEqual(2L, buffer.DroppedFrameCount);
        Assert.AreEqual(0.8F, buffer.PeakLevel, 0.0001F);
        CollectionAssert.AreEqual(input[..4], buffer.MakeSamples());
    }

    [TestMethod]
    public void ResetReusesCapacityWithoutRetainingAVisibleUtterance()
    {
        var buffer = new BoundedPcmBuffer(4);
        buffer.Append(new[] { 0.1F, 0.2F });
        buffer.Reset();
        Assert.AreEqual(0, buffer.FrameCount);
        Assert.AreEqual(0L, buffer.DroppedFrameCount);
        Assert.AreEqual(0F, buffer.PeakLevel);
        Assert.HasCount(0, buffer.MakeSamples());
    }

    [TestMethod]
    public void VadDetectsSpeechAndTrailingSilenceWithoutTrimmingFrames()
    {
        var configuration = new VoiceActivityConfiguration(0.02, 0.02F, 0.012F, 2, 0.1, 10);
        var detector = new EnergyVoiceActivityDetector(configuration, sampleRate: 1000);
        var input = Frames(0F, 0.04).Concat(Frames(0.1F, 0.06)).Concat(Frames(0F, 0.12)).ToArray();

        var observation = detector.Ingest(input);

        Assert.AreEqual(VoiceActivityState.EndedBySilence, observation.State);
        Assert.AreEqual(0.04, observation.SpeechStart!.Value, 0.0001);
        Assert.AreEqual(input.Length / 1000.0, observation.Elapsed, 0.0001);
        Assert.HasCount(input.Length, input);
    }

    [TestMethod]
    public void MaximumDurationIsTerminalEvenWithoutSpeech()
    {
        var configuration = VoiceActivityConfiguration.Default with { MaximumUtteranceDuration = 1 };
        var detector = new EnergyVoiceActivityDetector(configuration, sampleRate: 1000);
        var observation = detector.Ingest(new float[1000]);
        Assert.AreEqual(VoiceActivityState.EndedByMaximumDuration, observation.State);
    }

    [TestMethod]
    public void VoiceActivityConfigurationClampsToSafeBounds()
    {
        var configuration = new VoiceActivityConfiguration(0, -1, 10, 0, 0, 0).Validated();
        Assert.IsGreaterThanOrEqualTo(0.005, configuration.WindowDuration);
        Assert.IsGreaterThan(0F, configuration.SpeechThreshold);
        Assert.IsLessThanOrEqualTo(configuration.SpeechThreshold, configuration.SilenceThreshold);
        Assert.IsGreaterThanOrEqualTo(1, configuration.SpeechActivationWindows);
        Assert.IsGreaterThanOrEqualTo(0.1, configuration.TrailingSilenceDuration);
        Assert.IsGreaterThanOrEqualTo(1, configuration.MaximumUtteranceDuration);
        Assert.IsLessThanOrEqualTo(600, configuration.MaximumUtteranceDuration);
    }

    private static IEnumerable<float> Frames(float level, double duration, double sampleRate = 1000)
    {
        var count = (int)Math.Round(duration * sampleRate);
        return Enumerable.Repeat(level, count);
    }
}
