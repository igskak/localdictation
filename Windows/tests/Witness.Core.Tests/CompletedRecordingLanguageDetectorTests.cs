using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;

namespace Witness.Core.Tests;

[TestClass]
public sealed class CompletedRecordingLanguageDetectorTests
{
    [TestMethod]
    public async Task SingleLanguageDoesNotRunDetection()
    {
        var provider = new FakeProbabilityProvider();
        var detector = new CompletedRecordingLanguageDetector(provider);

        var result = await detector.DetectAsync(
            new float[] { 0.1F },
            new LanguageProfile(SpeechLanguage.German),
            previousLanguage: null,
            threadCount: 2);

        Assert.AreEqual(SpeechLanguage.German, result.Language);
        Assert.AreEqual(LanguageDecisionReason.OnlyLanguage, result.Reason);
        Assert.AreEqual(0, provider.CallCount);
    }

    [TestMethod]
    public async Task MixedProfileUsesCompleteRecordingAndSelectedSetPolicy()
    {
        var recording = new float[] { 0.1F, 0.2F, 0.3F, 0.4F };
        var provider = new FakeProbabilityProvider(new Dictionary<string, float>
        {
            ["pl"] = 0.99F,
            ["ru"] = 0.41F,
            ["uk"] = 0.40F,
        });
        var detector = new CompletedRecordingLanguageDetector(provider);

        var result = await detector.DetectAsync(
            recording,
            new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.Ukrainian),
            SpeechLanguage.Ukrainian,
            threadCount: 3);

        Assert.AreEqual(SpeechLanguage.Ukrainian, result.Language);
        Assert.AreEqual(LanguageDecisionReason.ContinuedFromPrevious, result.Reason);
        Assert.AreEqual(1, provider.CallCount);
        Assert.AreEqual(3, provider.ThreadCount);
        CollectionAssert.AreEqual(recording, provider.ReceivedRecording.ToArray());
    }

    [TestMethod]
    public async Task CancellationAfterProviderCannotCommitLanguage()
    {
        using var cancellation = new CancellationTokenSource();
        var provider = new FakeProbabilityProvider(
            new Dictionary<string, float> { ["en"] = 0.9F, ["de"] = 0.1F },
            () => cancellation.Cancel());
        var detector = new CompletedRecordingLanguageDetector(provider);

        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() => detector.DetectAsync(
            new float[] { 0.1F },
            new LanguageProfile(SpeechLanguage.German, SpeechLanguage.English),
            previousLanguage: null,
            threadCount: 1,
            cancellation.Token));
    }

    private sealed class FakeProbabilityProvider(
        IReadOnlyDictionary<string, float>? probabilities = null,
        Action? beforeReturn = null) : ILanguageProbabilityProvider
    {
        public int CallCount { get; private set; }
        public int ThreadCount { get; private set; }
        public ReadOnlyMemory<float> ReceivedRecording { get; private set; }

        public Task<IReadOnlyDictionary<string, float>> DetectProbabilitiesAsync(
            ReadOnlyMemory<float> completedPcm16KhzMono,
            int threadCount,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CallCount++;
            ThreadCount = threadCount;
            ReceivedRecording = completedPcm16KhzMono;
            beforeReturn?.Invoke();
            return Task.FromResult(probabilities
                ?? (IReadOnlyDictionary<string, float>)new Dictionary<string, float>());
        }
    }
}
