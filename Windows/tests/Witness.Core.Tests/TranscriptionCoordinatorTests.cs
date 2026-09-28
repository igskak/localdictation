using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Transcription;

namespace Witness.Core.Tests;

[TestClass]
public sealed class TranscriptionCoordinatorTests
{
    [TestMethod]
    public async Task AcceleratedSuccessDoesNotRunCpu()
    {
        var cpu = new FakeBackend(TranscriptionBackendKind.Cpu, Output(TranscriptionBackendKind.Cpu));
        var gpu = new FakeBackend(TranscriptionBackendKind.Vulkan, Output(TranscriptionBackendKind.Vulkan));
        await using var coordinator = new TranscriptionCoordinator(cpu, gpu);

        var result = await coordinator.TranscribeAsync(Request(), () => true);

        Assert.AreEqual(TranscriptionBackendKind.Vulkan, result.Backend);
        Assert.AreEqual(1, gpu.Calls);
        Assert.AreEqual(0, cpu.Calls);
    }

    [TestMethod]
    public async Task RetryableGpuFailureGetsExactlyOneCpuAttempt()
    {
        var cpu = new FakeBackend(TranscriptionBackendKind.Cpu, Output(TranscriptionBackendKind.Cpu));
        var gpu = new FakeBackend(
            TranscriptionBackendKind.Vulkan,
            new TranscriptionBackendException(
                TranscriptionBackendKind.Vulkan,
                TranscriptionBackendFailureKind.Execution,
                canRetryOnCpu: true,
                "GPU execution failed."));
        await using var coordinator = new TranscriptionCoordinator(cpu, gpu);

        var result = await coordinator.TranscribeAsync(Request(), () => true);

        Assert.AreEqual(TranscriptionBackendKind.Cpu, result.Backend);
        Assert.AreEqual(1, gpu.Calls);
        Assert.AreEqual(1, cpu.Calls);
    }

    [TestMethod]
    public async Task StaleOperationDoesNotRetryOnCpu()
    {
        var cpu = new FakeBackend(TranscriptionBackendKind.Cpu, Output(TranscriptionBackendKind.Cpu));
        var gpu = RetryableGpuFailure();
        await using var coordinator = new TranscriptionCoordinator(cpu, gpu);

        await Assert.ThrowsAsync<OperationCanceledException>(async () =>
            await coordinator.TranscribeAsync(Request(), () => false));

        Assert.AreEqual(1, gpu.Calls);
        Assert.AreEqual(0, cpu.Calls);
    }

    [TestMethod]
    public async Task NonRetryableFailureIsNotHiddenByCpu()
    {
        var cpu = new FakeBackend(TranscriptionBackendKind.Cpu, Output(TranscriptionBackendKind.Cpu));
        var failure = new TranscriptionBackendException(
            TranscriptionBackendKind.Vulkan,
            TranscriptionBackendFailureKind.ResourceExhausted,
            canRetryOnCpu: false,
            "Not enough memory.");
        var gpu = new FakeBackend(TranscriptionBackendKind.Vulkan, failure);
        await using var coordinator = new TranscriptionCoordinator(cpu, gpu);

        var thrown = await Assert.ThrowsAsync<TranscriptionBackendException>(async () =>
            await coordinator.TranscribeAsync(Request(), () => true));

        Assert.AreSame(failure, thrown);
        Assert.AreEqual(0, cpu.Calls);
    }

    [TestMethod]
    public async Task CancellationDoesNotStartCpuRetry()
    {
        var cpu = new FakeBackend(TranscriptionBackendKind.Cpu, Output(TranscriptionBackendKind.Cpu));
        var gpu = RetryableGpuFailure();
        await using var coordinator = new TranscriptionCoordinator(cpu, gpu);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(async () =>
            await coordinator.TranscribeAsync(Request(), () => true, cancellation.Token));

        Assert.AreEqual(0, gpu.Calls);
        Assert.AreEqual(0, cpu.Calls);
    }

    private static FakeBackend RetryableGpuFailure() => new(
        TranscriptionBackendKind.Vulkan,
        new TranscriptionBackendException(
            TranscriptionBackendKind.Vulkan,
            TranscriptionBackendFailureKind.Execution,
            canRetryOnCpu: true,
            "GPU execution failed."));

    private static TranscriptionRequest Request() => new(new float[] { 0.1F }, "en", 1);

    private static TranscriptionOutput Output(TranscriptionBackendKind backend) => new(
        "en",
        new MappedTranscript(" test", [], TranscriptionTimingGranularity.Segment),
        backend);

    private sealed class FakeBackend : ITranscriptionBackend
    {
        private readonly TranscriptionOutput? output;
        private readonly Exception? error;

        public FakeBackend(TranscriptionBackendKind kind, TranscriptionOutput output)
        {
            Kind = kind;
            this.output = output;
        }

        public FakeBackend(TranscriptionBackendKind kind, Exception error)
        {
            Kind = kind;
            this.error = error;
        }

        public TranscriptionBackendKind Kind { get; }
        public int Calls { get; private set; }

        public Task<TranscriptionOutput> TranscribeAsync(
            TranscriptionRequest request,
            CancellationToken cancellationToken)
        {
            Calls++;
            if (error is not null)
            {
                return Task.FromException<TranscriptionOutput>(error);
            }
            return Task.FromResult(output!);
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
