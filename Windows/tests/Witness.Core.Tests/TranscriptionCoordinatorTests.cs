using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;
using Witness.Core.Transcription;

namespace Witness.Core.Tests;

[TestClass]
public sealed class TranscriptionCoordinatorTests
{
    [TestMethod]
    public async Task AcceleratedSuccessNeverCreatesCpu()
    {
        var factory = new FakeFactory();
        await using var coordinator = await TranscriptionCoordinator.CreateAsync(factory, preferAccelerated: true);

        var result = await coordinator.TranscribeAsync(Request(), () => true);

        Assert.AreEqual(TranscriptionBackendKind.Vulkan, result.Backend);
        Assert.AreEqual(1, factory.GpuCreations);
        Assert.AreEqual(0, factory.CpuCreations);
    }

    [TestMethod]
    public async Task RetryableGpuLoadFailureCreatesCpuExactlyOnce()
    {
        var factory = new FakeFactory
        {
            GpuCreationError = Failure(TranscriptionBackendFailureKind.Initialization),
        };
        await using var coordinator = await TranscriptionCoordinator.CreateAsync(factory, preferAccelerated: true);

        var result = await coordinator.TranscribeAsync(Request(), () => true);

        Assert.AreEqual(TranscriptionBackendKind.Cpu, result.Backend);
        Assert.AreEqual(1, factory.GpuCreations);
        Assert.AreEqual(1, factory.CpuCreations);
        Assert.AreEqual(1, factory.Cpu!.TranscriptionCalls);
    }

    [TestMethod]
    public async Task RetryableGpuExecutionFailureDisposesGpuBeforeSingleCpuRetry()
    {
        var factory = new FakeFactory();
        factory.Gpu!.TranscriptionError = Failure(TranscriptionBackendFailureKind.Execution);
        await using var coordinator = await TranscriptionCoordinator.CreateAsync(factory, preferAccelerated: true);

        var result = await coordinator.TranscribeAsync(Request(), () => true);

        Assert.AreEqual(TranscriptionBackendKind.Cpu, result.Backend);
        Assert.AreEqual(1, factory.Gpu.TranscriptionCalls);
        Assert.AreEqual(1, factory.Gpu.DisposeCalls);
        Assert.AreEqual(1, factory.CpuCreations);
        Assert.AreEqual(1, factory.Cpu!.TranscriptionCalls);
        Assert.IsTrue(factory.CpuCreatedAfterGpuDisposed);
    }

    [TestMethod]
    public async Task RetryableGpuLanguageFailureUsesSameControlledCpuSwitch()
    {
        var factory = new FakeFactory();
        factory.Gpu!.DetectionError = Failure(TranscriptionBackendFailureKind.Execution);
        factory.Cpu!.Probabilities = new Dictionary<string, float> { ["uk"] = 0.8F };
        await using var coordinator = await TranscriptionCoordinator.CreateAsync(factory, preferAccelerated: true);

        var probabilities = await coordinator.DetectProbabilitiesAsync(new float[] { 0.1F }, 2, default);

        Assert.AreEqual(0.8F, probabilities["uk"]);
        Assert.AreEqual(1, factory.Gpu.DetectionCalls);
        Assert.AreEqual(1, factory.CpuCreations);
        Assert.AreEqual(1, factory.Cpu.DetectionCalls);
    }

    [TestMethod]
    public async Task StaleOperationDoesNotCreateCpu()
    {
        var factory = new FakeFactory();
        factory.Gpu!.TranscriptionError = Failure(TranscriptionBackendFailureKind.Execution);
        await using var coordinator = await TranscriptionCoordinator.CreateAsync(factory, preferAccelerated: true);

        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() =>
            coordinator.TranscribeAsync(Request(), () => false));

        Assert.AreEqual(0, factory.CpuCreations);
        Assert.AreEqual(0, factory.Gpu.DisposeCalls);
    }

    [TestMethod]
    public async Task NonRetryableFailureIsNotHiddenByCpu()
    {
        var factory = new FakeFactory();
        var failure = Failure(TranscriptionBackendFailureKind.ResourceExhausted, canRetry: false);
        factory.Gpu!.TranscriptionError = failure;
        await using var coordinator = await TranscriptionCoordinator.CreateAsync(factory, preferAccelerated: true);

        var thrown = await Assert.ThrowsExactlyAsync<TranscriptionBackendException>(() =>
            coordinator.TranscribeAsync(Request(), () => true));

        Assert.AreSame(failure, thrown);
        Assert.AreEqual(0, factory.CpuCreations);
    }

    [TestMethod]
    public async Task CancellationBeforeLoadCreatesNoBackend()
    {
        var factory = new FakeFactory();
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsExactlyAsync<OperationCanceledException>(() =>
            TranscriptionCoordinator.CreateAsync(factory, preferAccelerated: true, cancellation.Token));

        Assert.AreEqual(0, factory.GpuCreations);
        Assert.AreEqual(0, factory.CpuCreations);
    }

    [TestMethod]
    public async Task FactoryKindMismatchIsDisposedAndRejected()
    {
        var factory = new FakeFactory { ReturnCpuForGpu = true };

        var error = await Assert.ThrowsExactlyAsync<InvalidOperationException>(() =>
            TranscriptionCoordinator.CreateAsync(factory, preferAccelerated: true));

        StringAssert.Contains(error.Message, "when Vulkan was requested");
        Assert.AreEqual(1, factory.Cpu!.DisposeCalls);
        Assert.AreEqual(0, factory.CpuCreations);
    }

    private static TranscriptionBackendException Failure(
        TranscriptionBackendFailureKind kind,
        bool canRetry = true) => new(
            TranscriptionBackendKind.Vulkan,
            kind,
            canRetry,
            "Synthetic accelerated backend failure.");

    private static TranscriptionRequest Request() => new(new float[] { 0.1F }, "en", 1);

    private sealed class FakeFactory : ITranscriptionBackendFactory
    {
        public FakeFactory()
        {
            Gpu = new FakeBackend(TranscriptionBackendKind.Vulkan);
            Cpu = new FakeBackend(TranscriptionBackendKind.Cpu);
        }

        public FakeBackend? Gpu { get; }
        public FakeBackend? Cpu { get; }
        public Exception? GpuCreationError { get; init; }
        public bool ReturnCpuForGpu { get; init; }
        public int GpuCreations { get; private set; }
        public int CpuCreations { get; private set; }
        public bool CpuCreatedAfterGpuDisposed { get; private set; }

        public Task<ITranscriptionBackend> CreateAsync(
            TranscriptionBackendKind kind,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (kind == TranscriptionBackendKind.Vulkan)
            {
                GpuCreations++;
                return GpuCreationError is null
                    ? Task.FromResult<ITranscriptionBackend>(ReturnCpuForGpu ? Cpu! : Gpu!)
                    : Task.FromException<ITranscriptionBackend>(GpuCreationError);
            }

            CpuCreations++;
            CpuCreatedAfterGpuDisposed = Gpu!.DisposeCalls == 1;
            return Task.FromResult<ITranscriptionBackend>(Cpu!);
        }
    }

    private sealed class FakeBackend(TranscriptionBackendKind kind) : ITranscriptionBackend, ILanguageProbabilityProvider
    {
        public TranscriptionBackendKind Kind { get; } = kind;
        public Exception? TranscriptionError { get; set; }
        public Exception? DetectionError { get; set; }
        public IReadOnlyDictionary<string, float> Probabilities { get; set; } =
            new Dictionary<string, float> { ["en"] = 1F };
        public int TranscriptionCalls { get; private set; }
        public int DetectionCalls { get; private set; }
        public int DisposeCalls { get; private set; }

        public Task<TranscriptionOutput> TranscribeAsync(
            TranscriptionRequest request,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            TranscriptionCalls++;
            return TranscriptionError is null
                ? Task.FromResult(new TranscriptionOutput(
                    request.LanguageCode ?? "en",
                    new MappedTranscript(" test", [], TranscriptionTimingGranularity.Segment),
                    Kind))
                : Task.FromException<TranscriptionOutput>(TranscriptionError);
        }

        public Task<IReadOnlyDictionary<string, float>> DetectProbabilitiesAsync(
            ReadOnlyMemory<float> completedPcm16KhzMono,
            int threadCount,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            DetectionCalls++;
            return DetectionError is null
                ? Task.FromResult(Probabilities)
                : Task.FromException<IReadOnlyDictionary<string, float>>(DetectionError);
        }

        public ValueTask DisposeAsync()
        {
            DisposeCalls++;
            return ValueTask.CompletedTask;
        }
    }
}
