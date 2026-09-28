using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;
using Witness.Core.Transcription;

namespace Witness.Core.Tests;

[TestClass]
public sealed class LocalInferencePipelineTests
{
    [TestMethod]
    public async Task MixedProfileDetectsThenTranscribesWithExplicitLanguageAndClearsAudio()
    {
        var session = new FakeSession
        {
            Probabilities = new Dictionary<string, float> { ["ru"] = 0.1F, ["uk"] = 0.9F },
        };
        var factory = new FakeSessionFactory(session);
        await using var pipeline = new LocalInferencePipeline(factory);
        var audio = new float[] { 0.2F, -0.1F, 0.3F };

        var result = await pipeline.ProcessAsync(Request(
            audio,
            new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.Ukrainian)));

        Assert.AreEqual(SpeechLanguage.Ukrainian, result.LanguageDecision.Language);
        Assert.AreEqual("uk", session.Requests.Single().LanguageCode);
        Assert.AreEqual(1, session.DetectionCalls);
        CollectionAssert.AreEqual(new float[] { 0, 0, 0 }, audio);
    }

    [TestMethod]
    public async Task DetectionStartsAtVadBoundaryWhileTranscriptionKeepsTheFullPhrase()
    {
        var session = new FakeSession
        {
            Probabilities = new Dictionary<string, float> { ["en"] = 0.9F, ["de"] = 0.1F },
        };
        await using var pipeline = new LocalInferencePipeline(new FakeSessionFactory(session));
        var audio = new float[] { 0.001F, -0.001F, 0.2F, -0.3F };

        await pipeline.ProcessAsync(new LocalInferenceRequest(
            audio,
            ModelPath,
            new LanguageProfile(SpeechLanguage.German, SpeechLanguage.English),
            PinnedLanguage: null,
            ThreadCount: 2,
            DetectionStartSample: 2));

        CollectionAssert.AreEqual(new float[] { 0.2F, -0.3F }, session.DetectionAudio);
        CollectionAssert.AreEqual(new float[] { 0.001F, -0.001F, 0.2F, -0.3F }, session.TranscriptionAudio);
        CollectionAssert.AreEqual(new float[] { 0, 0, 0, 0 }, audio);
    }

    [TestMethod]
    public async Task PinRestrictsProfileAndSkipsDetection()
    {
        var session = new FakeSession();
        await using var pipeline = new LocalInferencePipeline(new FakeSessionFactory(session));

        var result = await pipeline.ProcessAsync(new LocalInferenceRequest(
            new float[] { 0.1F },
            ModelPath,
            new LanguageProfile(SpeechLanguage.German, SpeechLanguage.English),
            SpeechLanguage.German,
            2));

        Assert.AreEqual(LanguageDecisionReason.OnlyLanguage, result.LanguageDecision.Reason);
        Assert.AreEqual("de", session.Requests.Single().LanguageCode);
        Assert.AreEqual(0, session.DetectionCalls);
    }

    [TestMethod]
    public async Task SameVerifiedModelSessionIsReusedAcrossPhrases()
    {
        var session = new FakeSession();
        var factory = new FakeSessionFactory(session);
        await using var pipeline = new LocalInferencePipeline(factory);

        await pipeline.ProcessAsync(Request(new float[] { 0.1F }, new LanguageProfile(SpeechLanguage.English)));
        await pipeline.ProcessAsync(Request(new float[] { 0.2F }, new LanguageProfile(SpeechLanguage.English)));

        Assert.AreEqual(1, factory.Calls);
        Assert.AreEqual(2, session.Requests.Count);
    }

    [TestMethod]
    public async Task SupersededGenerationCannotTranscribeAndBothBuffersAreCleared()
    {
        var session = new FakeSession { BlockFirstDetection = true };
        await using var pipeline = new LocalInferencePipeline(new FakeSessionFactory(session));
        var firstAudio = new float[] { 0.4F };
        var secondAudio = new float[] { 0.5F };

        var first = pipeline.ProcessAsync(Request(
            firstAudio,
            new LanguageProfile(SpeechLanguage.German, SpeechLanguage.English)));
        await session.FirstDetectionStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var second = pipeline.ProcessAsync(Request(secondAudio, new LanguageProfile(SpeechLanguage.English)));

        await Assert.ThrowsAsync<OperationCanceledException>(() => first);
        await second;

        Assert.AreEqual(1, session.Requests.Count);
        Assert.AreEqual("en", session.Requests[0].LanguageCode);
        CollectionAssert.AreEqual(new float[] { 0 }, firstAudio);
        CollectionAssert.AreEqual(new float[] { 0 }, secondAudio);
    }

    [TestMethod]
    public async Task FailureDoesNotRetainCompletedAudio()
    {
        var session = new FakeSession { TranscriptionError = new InvalidOperationException("synthetic") };
        await using var pipeline = new LocalInferencePipeline(new FakeSessionFactory(session));
        var audio = new float[] { 0.4F, 0.5F };

        await Assert.ThrowsExactlyAsync<InvalidOperationException>(() => pipeline.ProcessAsync(Request(
            audio,
            new LanguageProfile(SpeechLanguage.English))));

        CollectionAssert.AreEqual(new float[] { 0, 0 }, audio);
    }

    [TestMethod]
    public async Task EngineLanguageMismatchIsReportedInsteadOfPolishedAway()
    {
        var session = new FakeSession { ReturnedLanguageCode = "de" };
        await using var pipeline = new LocalInferencePipeline(new FakeSessionFactory(session));

        var error = await Assert.ThrowsExactlyAsync<InvalidOperationException>(() => pipeline.ProcessAsync(Request(
            new float[] { 0.1F },
            new LanguageProfile(SpeechLanguage.English))));

        StringAssert.Contains(error.Message, "explicit language");
    }

    private static readonly string ModelPath = Path.GetFullPath("verified-model.bin");

    private static LocalInferenceRequest Request(float[] audio, LanguageProfile profile) => new(
        audio,
        ModelPath,
        profile,
        PinnedLanguage: null,
        ThreadCount: 2);

    private sealed class FakeSessionFactory(params FakeSession[] sessions) : ILocalTranscriptionSessionFactory
    {
        private int index;
        public int Calls { get; private set; }

        public Task<ILocalTranscriptionSession> CreateAsync(
            string verifiedModelPath,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Assert.AreEqual(ModelPath, verifiedModelPath);
            Calls++;
            return Task.FromResult<ILocalTranscriptionSession>(sessions[Math.Min(index++, sessions.Length - 1)]);
        }
    }

    private sealed class FakeSession : ILocalTranscriptionSession
    {
        public TranscriptionBackendKind Backend => TranscriptionBackendKind.Cpu;
        public IReadOnlyDictionary<string, float> Probabilities { get; init; } =
            new Dictionary<string, float> { ["en"] = 1F };
        public string? ReturnedLanguageCode { get; init; }
        public Exception? TranscriptionError { get; init; }
        public bool BlockFirstDetection { get; init; }
        public TaskCompletionSource FirstDetectionStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<TranscriptionRequest> Requests { get; } = [];
        public float[]? DetectionAudio { get; private set; }
        public float[]? TranscriptionAudio { get; private set; }
        public int DetectionCalls { get; private set; }

        public async Task<IReadOnlyDictionary<string, float>> DetectProbabilitiesAsync(
            ReadOnlyMemory<float> completedPcm16KhzMono,
            int threadCount,
            CancellationToken cancellationToken)
        {
            DetectionCalls++;
            DetectionAudio = completedPcm16KhzMono.ToArray();
            if (BlockFirstDetection && DetectionCalls == 1)
            {
                FirstDetectionStarted.SetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }
            return Probabilities;
        }

        public Task<TranscriptionOutput> TranscribeAsync(
            TranscriptionRequest request,
            Func<bool> isCurrentOperation,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!isCurrentOperation())
            {
                throw new OperationCanceledException();
            }
            Requests.Add(request);
            TranscriptionAudio = request.Pcm16KhzMono.ToArray();
            return TranscriptionError is null
                ? Task.FromResult(new TranscriptionOutput(
                    ReturnedLanguageCode ?? request.LanguageCode!,
                    new MappedTranscript(" synthetic", [], TranscriptionTimingGranularity.Segment),
                    Backend))
                : Task.FromException<TranscriptionOutput>(TranscriptionError);
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
