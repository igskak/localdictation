using Witness.Core.Languages;

namespace Witness.Core.Transcription;

public enum TranscriptionBackendKind
{
    Cpu,
    Vulkan,
}

public enum TranscriptionBackendFailureKind
{
    Unavailable,
    Initialization,
    Execution,
    ResourceExhausted,
}

public sealed record TranscriptionRequest(
    ReadOnlyMemory<float> Pcm16KhzMono,
    string? LanguageCode,
    int ThreadCount);

public sealed record TranscriptionOutput(
    string LanguageCode,
    MappedTranscript Transcript,
    TranscriptionBackendKind Backend);

public interface ITranscriptionBackend : IAsyncDisposable
{
    TranscriptionBackendKind Kind { get; }

    Task<TranscriptionOutput> TranscribeAsync(
        TranscriptionRequest request,
        CancellationToken cancellationToken);
}

public interface ITranscriptionBackendFactory
{
    Task<ITranscriptionBackend> CreateAsync(
        TranscriptionBackendKind kind,
        CancellationToken cancellationToken);
}

public interface ILocalTranscriptionSession : ILanguageProbabilityProvider, IAsyncDisposable
{
    TranscriptionBackendKind Backend { get; }

    Task<TranscriptionOutput> TranscribeAsync(
        TranscriptionRequest request,
        Func<bool> isCurrentOperation,
        CancellationToken cancellationToken = default);
}

public sealed class TranscriptionBackendException(
    TranscriptionBackendKind backend,
    TranscriptionBackendFailureKind failureKind,
    bool canRetryOnCpu,
    string message,
    Exception? innerException = null) : Exception(message, innerException)
{
    public TranscriptionBackendKind Backend { get; } = backend;
    public TranscriptionBackendFailureKind FailureKind { get; } = failureKind;
    public bool CanRetryOnCpu { get; } = canRetryOnCpu;
}

/// <summary>
/// Owns exactly one loaded speech backend. An accelerated initialization or
/// execution failure can replace it with one CPU backend, once, while the
/// caller's operation is still current.
/// </summary>
public sealed class TranscriptionCoordinator : ILocalTranscriptionSession
{
    private readonly ITranscriptionBackendFactory factory;
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private ITranscriptionBackend backend;
    private bool cpuCreationAttempted;
    private bool disposed;

    private TranscriptionCoordinator(
        ITranscriptionBackendFactory factory,
        ITranscriptionBackend backend,
        bool cpuCreationAttempted)
    {
        this.factory = factory;
        this.backend = backend;
        this.cpuCreationAttempted = cpuCreationAttempted;
    }

    public TranscriptionBackendKind Backend => backend.Kind;

    public static async Task<TranscriptionCoordinator> CreateAsync(
        ITranscriptionBackendFactory factory,
        bool preferAccelerated,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(factory);
        cancellationToken.ThrowIfCancellationRequested();

        if (preferAccelerated)
        {
            try
            {
                var accelerated = await factory
                    .CreateAsync(TranscriptionBackendKind.Vulkan, cancellationToken)
                    .ConfigureAwait(false);
                await ValidateKindOrDisposeAsync(
                    accelerated,
                    TranscriptionBackendKind.Vulkan).ConfigureAwait(false);
                return new TranscriptionCoordinator(factory, accelerated, cpuCreationAttempted: false);
            }
            catch (TranscriptionBackendException error) when (error.CanRetryOnCpu)
            {
                cancellationToken.ThrowIfCancellationRequested();
                // The failed factory call must not retain a native session.
                // Exactly one explicit CPU creation follows below.
            }
        }

        var cpu = await factory
            .CreateAsync(TranscriptionBackendKind.Cpu, cancellationToken)
            .ConfigureAwait(false);
        await ValidateKindOrDisposeAsync(cpu, TranscriptionBackendKind.Cpu).ConfigureAwait(false);
        return new TranscriptionCoordinator(factory, cpu, cpuCreationAttempted: true);
    }

    public async Task<TranscriptionOutput> TranscribeAsync(
        TranscriptionRequest request,
        Func<bool> isCurrentOperation,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(isCurrentOperation);
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfUnavailable(isCurrentOperation, cancellationToken);
            try
            {
                return await backend.TranscribeAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (TranscriptionBackendException error) when (CanSwitchToCpu(error))
            {
                await SwitchToCpuAsync(isCurrentOperation, cancellationToken).ConfigureAwait(false);
                return await backend.TranscribeAsync(request, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task<IReadOnlyDictionary<string, float>> DetectProbabilitiesAsync(
        ReadOnlyMemory<float> completedPcm16KhzMono,
        int threadCount,
        CancellationToken cancellationToken)
    {
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            try
            {
                return await ProbabilityProvider().DetectProbabilitiesAsync(
                    completedPcm16KhzMono,
                    threadCount,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (TranscriptionBackendException error) when (CanSwitchToCpu(error))
            {
                await SwitchToCpuAsync(static () => true, cancellationToken).ConfigureAwait(false);
                return await ProbabilityProvider().DetectProbabilitiesAsync(
                    completedPcm16KhzMono,
                    threadCount,
                    cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            await backend.DisposeAsync().ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
            operationGate.Dispose();
        }
    }

    private bool CanSwitchToCpu(TranscriptionBackendException error) =>
        backend.Kind != TranscriptionBackendKind.Cpu
        && !cpuCreationAttempted
        && error.CanRetryOnCpu;

    private async Task SwitchToCpuAsync(
        Func<bool> isCurrentOperation,
        CancellationToken cancellationToken)
    {
        ThrowIfUnavailable(isCurrentOperation, cancellationToken);
        cpuCreationAttempted = true;
        var failedBackend = backend;
        await failedBackend.DisposeAsync().ConfigureAwait(false);
        ThrowIfUnavailable(isCurrentOperation, cancellationToken);

        var cpu = await factory
            .CreateAsync(TranscriptionBackendKind.Cpu, cancellationToken)
            .ConfigureAwait(false);
        try
        {
            ValidateKind(cpu, TranscriptionBackendKind.Cpu);
            ThrowIfUnavailable(isCurrentOperation, cancellationToken);
            backend = cpu;
        }
        catch
        {
            await cpu.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private ILanguageProbabilityProvider ProbabilityProvider() =>
        backend as ILanguageProbabilityProvider
        ?? throw new InvalidOperationException("The active transcription backend does not support language detection.");

    private void ThrowIfUnavailable(Func<bool> isCurrentOperation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ThrowIfDisposed();
        if (!isCurrentOperation())
        {
            throw new OperationCanceledException("The transcription operation is no longer current.");
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(disposed, this);

    private static void ValidateKind(ITranscriptionBackend backend, TranscriptionBackendKind expected)
    {
        ArgumentNullException.ThrowIfNull(backend);
        if (backend.Kind != expected)
        {
            throw new InvalidOperationException($"The backend factory returned {backend.Kind} when {expected} was requested.");
        }
    }

    private static async Task ValidateKindOrDisposeAsync(
        ITranscriptionBackend backend,
        TranscriptionBackendKind expected)
    {
        try
        {
            ValidateKind(backend, expected);
        }
        catch
        {
            if (backend is not null)
            {
                await backend.DisposeAsync().ConfigureAwait(false);
            }
            throw;
        }
    }
}
