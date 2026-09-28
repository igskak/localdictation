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

public sealed class TranscriptionCoordinator(
    ITranscriptionBackend cpu,
    ITranscriptionBackend? accelerated = null) : IAsyncDisposable
{
    public async Task<TranscriptionOutput> TranscribeAsync(
        TranscriptionRequest request,
        Func<bool> isCurrentOperation,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(isCurrentOperation);
        cancellationToken.ThrowIfCancellationRequested();
        if (cpu.Kind != TranscriptionBackendKind.Cpu)
        {
            throw new ArgumentException("The fallback backend must be CPU.", nameof(cpu));
        }
        if (accelerated is not null && accelerated.Kind == TranscriptionBackendKind.Cpu)
        {
            throw new ArgumentException("The accelerated backend must not be CPU.", nameof(accelerated));
        }

        if (accelerated is not null)
        {
            try
            {
                return await accelerated.TranscribeAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (TranscriptionBackendException error) when (error.CanRetryOnCpu)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!isCurrentOperation())
                {
                    throw new OperationCanceledException("The transcription operation is no longer current.");
                }
                // Exactly one controlled retry. CPU failures propagate and are
                // never turned into a false successful empty transcript.
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (!isCurrentOperation())
        {
            throw new OperationCanceledException("The transcription operation is no longer current.");
        }
        return await cpu.TranscribeAsync(request, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (accelerated is not null && !ReferenceEquals(accelerated, cpu))
        {
            await accelerated.DisposeAsync().ConfigureAwait(false);
        }
        await cpu.DisposeAsync().ConfigureAwait(false);
    }
}
