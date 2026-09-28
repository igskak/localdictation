using Witness.Core.Languages;
using Witness.Core.Recording;

namespace Witness.Core.Transcription;

public enum LocalInferenceStage
{
    LoadingModel,
    DetectingLanguage,
    Transcribing,
    Completed,
}

public sealed record LocalInferenceProgress(
    LocalInferenceStage Stage,
    SpeechLanguage? Language = null,
    TranscriptionBackendKind? Backend = null);

public sealed record LocalInferenceRequest(
    float[] CompletedPcm16KhzMono,
    string ModelPath,
    LanguageProfile Profile,
    SpeechLanguage? PinnedLanguage,
    int ThreadCount);

public sealed record LocalInferenceResult(
    LanguageDecisionResult LanguageDecision,
    TranscriptionOutput Transcription);

public interface ILocalTranscriptionSessionFactory
{
    Task<ILocalTranscriptionSession> CreateAsync(
        string verifiedModelPath,
        CancellationToken cancellationToken);
}

/// <summary>
/// Runs completed in-memory audio through final language selection and an
/// explicit-language transcription. It retains one verified model session,
/// cancels superseded generations, and clears the caller-owned audio array as
/// soon as the inference attempt ends.
/// </summary>
public sealed class LocalInferencePipeline(
    ILocalTranscriptionSessionFactory sessionFactory,
    TimeProvider? timeProvider = null) : IAsyncDisposable
{
    private readonly object stateGate = new();
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private readonly OperationGeneration generations = new();
    private readonly LanguageContinuity continuity = new();
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private CancellationTokenSource? activeCancellation;
    private ILocalTranscriptionSession? session;
    private string? sessionModelPath;
    private bool disposed;

    public event EventHandler<LocalInferenceProgress>? ProgressChanged;

    public async Task<LocalInferenceResult> ProcessAsync(
        LocalInferenceRequest request,
        CancellationToken cancellationToken = default)
    {
        Validate(request);
        var generation = generations.Supersede();
        CancellationTokenSource operationCancellation;
        lock (stateGate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            activeCancellation?.Cancel();
            activeCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            operationCancellation = activeCancellation;
        }

        var entered = false;
        try
        {
            await operationGate.WaitAsync(operationCancellation.Token).ConfigureAwait(false);
            entered = true;
            EnsureCurrent(generation, operationCancellation.Token);

            var activeSession = await GetSessionAsync(
                request.ModelPath,
                generation,
                operationCancellation.Token).ConfigureAwait(false);
            var effectiveProfile = request.Profile.EffectiveForPin(request.PinnedLanguage);
            var now = clock.GetUtcNow();
            var previous = continuity.PreviousAt(now);
            if (effectiveProfile.IsMixed)
            {
                Report(new LocalInferenceProgress(LocalInferenceStage.DetectingLanguage, Backend: activeSession.Backend));
            }

            var detector = new CompletedRecordingLanguageDetector(activeSession);
            var decision = await detector.DetectAsync(
                request.CompletedPcm16KhzMono,
                effectiveProfile,
                previous,
                request.ThreadCount,
                operationCancellation.Token).ConfigureAwait(false);
            EnsureCurrent(generation, operationCancellation.Token);

            Report(new LocalInferenceProgress(
                LocalInferenceStage.Transcribing,
                decision.Language,
                activeSession.Backend));
            var transcription = await activeSession.TranscribeAsync(
                new TranscriptionRequest(
                    request.CompletedPcm16KhzMono,
                    decision.Language.Code,
                    request.ThreadCount),
                () => generations.IsCurrent(generation),
                operationCancellation.Token).ConfigureAwait(false);
            EnsureCurrent(generation, operationCancellation.Token);

            if (!string.Equals(transcription.LanguageCode, decision.Language.Code, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The local speech engine did not honor the explicit language decision.");
            }

            continuity.Observe(decision.Language, clock.GetUtcNow());
            Report(new LocalInferenceProgress(
                LocalInferenceStage.Completed,
                decision.Language,
                transcription.Backend));
            return new LocalInferenceResult(decision, transcription);
        }
        finally
        {
            Array.Clear(request.CompletedPcm16KhzMono);
            if (entered)
            {
                operationGate.Release();
            }
            lock (stateGate)
            {
                if (ReferenceEquals(activeCancellation, operationCancellation))
                {
                    activeCancellation = null;
                }
            }
            operationCancellation.Dispose();
        }
    }

    public bool CancelActive()
    {
        lock (stateGate)
        {
            if (activeCancellation is null)
            {
                return false;
            }
            generations.Supersede();
            activeCancellation.Cancel();
            return true;
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (stateGate)
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            generations.Supersede();
            activeCancellation?.Cancel();
        }

        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (session is not null)
            {
                await session.DisposeAsync().ConfigureAwait(false);
                session = null;
                sessionModelPath = null;
            }
        }
        finally
        {
            operationGate.Release();
            operationGate.Dispose();
        }
    }

    private async Task<ILocalTranscriptionSession> GetSessionAsync(
        string modelPath,
        long generation,
        CancellationToken cancellationToken)
    {
        var normalizedPath = Path.GetFullPath(modelPath);
        if (session is not null && string.Equals(sessionModelPath, normalizedPath, StringComparison.Ordinal))
        {
            return session;
        }

        Report(new LocalInferenceProgress(LocalInferenceStage.LoadingModel));
        if (session is not null)
        {
            await session.DisposeAsync().ConfigureAwait(false);
            session = null;
            sessionModelPath = null;
        }

        var created = await sessionFactory.CreateAsync(normalizedPath, cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureCurrent(generation, cancellationToken);
            session = created;
            sessionModelPath = normalizedPath;
            return created;
        }
        catch
        {
            await created.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private void EnsureCurrent(long generation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!generations.IsCurrent(generation))
        {
            throw new OperationCanceledException("The local inference operation is no longer current.");
        }
    }

    private void Report(LocalInferenceProgress progress) => ProgressChanged?.Invoke(this, progress);

    private static void Validate(LocalInferenceRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(request.CompletedPcm16KhzMono);
        ArgumentNullException.ThrowIfNull(request.Profile);
        if (request.CompletedPcm16KhzMono.Length == 0)
        {
            throw new ArgumentException("Completed audio is required.", nameof(request));
        }
        ArgumentException.ThrowIfNullOrWhiteSpace(request.ModelPath);
        if (request.ThreadCount < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(request), "At least one inference thread is required.");
        }
    }
}
