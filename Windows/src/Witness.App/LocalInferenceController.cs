using System.Windows.Threading;
using Witness.Core.History;
using Witness.Core.Input;
using Witness.Core.Languages;
using Witness.Core.Recording;
using Witness.Core.Review;
using Witness.Core.Transcription;
using Witness.Platform.Windows.Audio;
using Witness.Platform.Windows.Insertion;
using Witness.Platform.Windows.Transcription;

namespace Witness.App;

internal sealed class LocalInferenceController : IAsyncDisposable
{
    private const int EngineSampleRate = 16_000;
    private readonly Dispatcher dispatcher;
    private readonly MainWindow window;
    private readonly LocalInferencePipeline pipeline;
    private readonly TextInsertionCoordinator insertion;
    private readonly HotkeyModifiers hotkeyModifiers;
    private readonly OperationGeneration insertionGenerations = new();
    private readonly Witness.Platform.Windows.Review.WindowsSpellCheckingLexicon lexicon = new();
    private readonly DictationPostProcessor postProcessor;
    private readonly RecentDictationHistory history = new();
    private readonly SessionGlossary sessionGlossary = new();
    private readonly ReviewAudioLease reviewAudio = new();
    private readonly Witness.Platform.Windows.Review.IAudioFragmentPlayer fragmentPlayer;
    private readonly object resultGate = new();
    private string? verifiedModelPath;
    private LanguageProfile? selectedProfile;
    private ProcessedDictation? latestResult;
    private bool disposed;

    internal event EventHandler? PrivacyStateChanged;

    public LocalInferenceController(
        Dispatcher dispatcher,
        MainWindow window,
        TextInsertionCoordinator insertion,
        HotkeyModifiers hotkeyModifiers,
        Witness.Platform.Windows.Review.IAudioFragmentPlayer fragmentPlayer)
    {
        this.dispatcher = dispatcher;
        this.window = window;
        this.insertion = insertion;
        this.hotkeyModifiers = hotkeyModifiers;
        this.fragmentPlayer = fragmentPlayer;
        postProcessor = new DictationPostProcessor(riskEngine: RiskEngine.Standard(lexicon: lexicon));
        pipeline = new LocalInferencePipeline(new NativeTranscriptionSessionFactory());
        pipeline.ProgressChanged += OnProgressChanged;
    }

    public void SetVerifiedModelPath(string modelPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(modelPath);
        Volatile.Write(ref verifiedModelPath, modelPath);
    }

    public void SetLanguageProfile(LanguageProfile profile) =>
        Volatile.Write(ref selectedProfile, profile ?? throw new ArgumentNullException(nameof(profile)));

    internal IReadOnlyList<RecentDictation> RecentDictations
    {
        get
        {
            lock (resultGate)
            {
                return history.Items.ToArray();
            }
        }
    }

    internal ProcessedDictation? LatestResult
    {
        get
        {
            lock (resultGate)
            {
                return latestResult;
            }
        }
    }

    internal bool HasRetainedReviewAudio => reviewAudio.HasAudio;

    internal IReadOnlyList<GlossaryEntry> GlossaryEntries
    {
        get
        {
            lock (resultGate)
            {
                return sessionGlossary.Entries;
            }
        }
    }

    internal IReadOnlyList<string> LexiconCapabilities => LanguageCatalog.All
        .Where(entry => entry.Code is "de" or "en" or "ru" or "uk")
        .Select(entry =>
        {
            var language = new SpeechLanguage(entry.Code);
            return $"{entry.Code}: {window.ResourceText(lexicon.Supports(language) ? "LexiconAvailable" : "LexiconDisabled")}";
        })
        .ToArray();

    internal SessionGlossaryAddResult AddGlossaryTerm(string term, SpeechLanguage language)
    {
        var profile = Volatile.Read(ref selectedProfile);
        if (profile is null) return SessionGlossaryAddResult.LanguageNotSelected;
        SessionGlossaryAddResult result;
        lock (resultGate)
        {
            result = sessionGlossary.Add(term, language, profile);
        }
        if (result == SessionGlossaryAddResult.Added) PrivacyStateChanged?.Invoke(this, EventArgs.Empty);
        return result;
    }

    internal bool RemoveGlossaryTerm(GlossaryEntry entry)
    {
        bool removed;
        lock (resultGate)
        {
            removed = sessionGlossary.Remove(entry.Term, entry.Language);
        }
        if (removed) PrivacyStateChanged?.Invoke(this, EventArgs.Empty);
        return removed;
    }

    internal void DismissReview()
    {
        lock (resultGate)
        {
            fragmentPlayer.Stop();
            reviewAudio.Release();
        }
        PrivacyStateChanged?.Invoke(this, EventArgs.Empty);
    }

    internal bool Replay(RiskSpan span)
    {
        ArgumentNullException.ThrowIfNull(span);
        float[] fragment;
        lock (resultGate)
        {
            if (latestResult is null
                || !latestResult.Review.Flagged.Contains(span)
                || !reviewAudio.TryCopyFlaggedFragment(span, out fragment))
            {
                return false;
            }
        }
        try
        {
            return fragmentPlayer.TryPlay(fragment, EngineSampleRate);
        }
        finally
        {
            Array.Clear(fragment);
        }
    }

    public long BeginOperation()
    {
        lock (resultGate)
        {
            pipeline.CancelActive();
            var generation = insertionGenerations.Supersede();
            fragmentPlayer.Stop();
            reviewAudio.Release();
            latestResult = null;
            dispatcher.BeginInvoke(window.BeginDictation);
            PrivacyStateChanged?.Invoke(this, EventArgs.Empty);
            return generation;
        }
    }

    public async Task<bool> ProcessAsync(
        AudioCaptureResult capture,
        InsertionTarget? capturedTarget,
        long generation)
    {
        if (capture.Kind is not (AudioCaptureCompletionKind.Speech or AudioCaptureCompletionKind.InterruptedWithSpeech))
        {
            return false;
        }

        var modelPath = Volatile.Read(ref verifiedModelPath);
        var profile = Volatile.Read(ref selectedProfile);
        if (profile is null)
        {
            Array.Clear(capture.Pcm16KhzMono);
            await SetStatusResourceAsync("ChooseLanguageProfile").ConfigureAwait(false);
            return true;
        }
        if (modelPath is null)
        {
            Array.Clear(capture.Pcm16KhzMono);
            await SetStatusResourceAsync("VerifiedModelNotReady").ConfigureAwait(false);
            return true;
        }

        var completedAudioHandled = false;
        try
        {
            if (!insertionGenerations.IsCurrent(generation)) return true;
            var detectionStartSample = capture.SpeechStartSeconds is double speechStart && speechStart > 0
                ? Math.Min((int)Math.Floor(speechStart * EngineSampleRate), capture.Pcm16KhzMono.Length - 1)
                : 0;
            var result = await pipeline.ProcessAsync(new LocalInferenceRequest(
                capture.Pcm16KhzMono,
                modelPath,
                profile,
                PinnedLanguage: null,
                ThreadCount: Math.Clamp(Environment.ProcessorCount - 1, 1, 8),
                DetectionStartSample: detectionStartSample,
                ClearCompletedAudioOnExit: false)).ConfigureAwait(false);
            if (!insertionGenerations.IsCurrent(generation)) return true;
            var warning = capture.Kind == AudioCaptureCompletionKind.InterruptedWithSpeech
                || capture.HadDiscontinuity
                || capture.BufferOverflowed
                || capture.DroppedPacketCount > 0
                ? await ResourceTextAsync("CaptureWarning").ConfigureAwait(false)
                : string.Empty;
            IReadOnlyList<GlossaryEntry> glossary;
            lock (resultGate)
            {
                glossary = sessionGlossary.Entries;
            }
            var processed = postProcessor.Process(
                result.Transcription.Transcript,
                result.LanguageDecision.Language,
                profile,
                glossary);
            if (string.IsNullOrWhiteSpace(processed.TextForInsertion))
            {
                IReadOnlyList<RecentDictation> recent;
                lock (resultGate)
                {
                    if (!insertionGenerations.IsCurrent(generation))
                    {
                        return true;
                    }
                    reviewAudio.Replace(capture.Pcm16KhzMono, EngineSampleRate, processed);
                    latestResult = null;
                    completedAudioHandled = true;
                    recent = history.Items.ToArray();
                }
                await PublishClearedResultAsync(recent, generation).ConfigureAwait(false);
                PrivacyStateChanged?.Invoke(this, EventArgs.Empty);
                await SetStatusResourceAsync(
                    generation,
                    "EmptyTranscript",
                    DisplayLanguage(result.LanguageDecision.Language),
                    warning).ConfigureAwait(false);
                return true;
            }

            var insertionResult = await insertion.InsertAsync(
                processed.TextForInsertion,
                capturedTarget,
                hotkeyModifiers,
                () => insertionGenerations.IsCurrent(generation)).ConfigureAwait(false);
            if (insertionResult.Kind == TextInsertionOutcomeKind.Cancelled)
            {
                return true;
            }

            IReadOnlyList<RecentDictation> recentDictations;
            var showResult = true;
            lock (resultGate)
            {
                if (!insertionGenerations.IsCurrent(generation))
                {
                    return true;
                }
                var protectedRefusal = insertionResult.Kind == TextInsertionOutcomeKind.RefusedProtectedField;
                history.Add(
                    processed.TextForInsertion,
                    DateTimeOffset.UtcNow,
                    insertionRefusedForProtectedField: protectedRefusal);
                if (protectedRefusal)
                {
                    Array.Clear(capture.Pcm16KhzMono);
                    latestResult = null;
                    showResult = false;
                }
                else
                {
                    reviewAudio.Replace(capture.Pcm16KhzMono, EngineSampleRate, processed);
                    latestResult = processed;
                }
                completedAudioHandled = true;
                recentDictations = history.Items.ToArray();
            }
            if (showResult)
            {
                await PublishResultAsync(processed, recentDictations, generation).ConfigureAwait(false);
            }
            else
            {
                await PublishClearedResultAsync(recentDictations, generation).ConfigureAwait(false);
            }
            await SetInsertionStatusAsync(insertionResult, result, processed, warning, generation).ConfigureAwait(false);
            PrivacyStateChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (OperationCanceledException)
        {
            // A newer completed phrase or shutdown superseded this generation.
        }
        catch (Exception error)
        {
            await SetTranscriptionErrorStatusAsync(error, generation).ConfigureAwait(false);
        }
        finally
        {
            if (!completedAudioHandled)
            {
                Array.Clear(capture.Pcm16KhzMono);
            }
        }
        return true;
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        lock (resultGate)
        {
            insertionGenerations.Supersede();
            pipeline.CancelActive();
            reviewAudio.Dispose();
            fragmentPlayer.Dispose();
            latestResult = null;
            history.Clear();
            sessionGlossary.Clear();
        }
        pipeline.ProgressChanged -= OnProgressChanged;
        await pipeline.DisposeAsync().ConfigureAwait(false);
    }

    private void OnProgressChanged(object? sender, LocalInferenceProgress progress)
    {
        if (disposed)
        {
            return;
        }
        (string Key, object[] Arguments)? status = progress.Stage switch
        {
            LocalInferenceStage.LoadingModel => ("ProgressLoadingModel", Array.Empty<object>()),
            LocalInferenceStage.DetectingLanguage => ("ProgressDetectingLanguage", Array.Empty<object>()),
            LocalInferenceStage.Transcribing => ("ProgressTranscribing", new object[] { DisplayLanguage(progress.Language!.Value) }),
            _ => null,
        };
        if (status is not null)
        {
            dispatcher.BeginInvoke(() => window.SetStatus(window.ResourceFormat(status.Value.Key, status.Value.Arguments)));
        }
    }

    private async Task<string> ResourceTextAsync(string key) =>
        await dispatcher.InvokeAsync(() => window.ResourceText(key));

    private async Task SetStatusResourceAsync(string key, params object[] arguments) =>
        await dispatcher.InvokeAsync(() => window.SetStatus(window.ResourceFormat(key, arguments)));

    private async Task SetStatusResourceAsync(long generation, string key, params object[] arguments) =>
        await dispatcher.InvokeAsync(() =>
        {
            if (insertionGenerations.IsCurrent(generation))
            {
                window.SetStatus(window.ResourceFormat(key, arguments));
            }
        });

    private async Task SetInsertionStatusAsync(
        TextInsertionOutcome outcome,
        LocalInferenceResult inference,
        ProcessedDictation processed,
        string warning,
        long generation) =>
        await dispatcher.InvokeAsync(() =>
        {
            if (insertionGenerations.IsCurrent(generation))
                window.SetStatus(InsertionStatus(outcome, inference, processed, warning));
        });

    private async Task SetTranscriptionErrorStatusAsync(Exception error, long generation) =>
        await dispatcher.InvokeAsync(() =>
        {
            if (insertionGenerations.IsCurrent(generation))
                window.SetStatus(window.ResourceFormat("TranscriptionFailed", SafeError(error)));
        });

    private async Task PublishResultAsync(
        ProcessedDictation result,
        IReadOnlyList<RecentDictation> recentDictations,
        long generation) =>
        await dispatcher.InvokeAsync(() =>
        {
            if (insertionGenerations.IsCurrent(generation))
            {
                window.ShowDictationResult(result, recentDictations);
            }
        });

    private async Task PublishClearedResultAsync(
        IReadOnlyList<RecentDictation> recentDictations,
        long generation) =>
        await dispatcher.InvokeAsync(() =>
        {
            if (insertionGenerations.IsCurrent(generation))
            {
                window.ClearDictationResult(recentDictations);
            }
        });

    private static string DisplayLanguage(SpeechLanguage language) =>
        LanguageCatalog.ByCode.TryGetValue(language.Code, out var entry)
            ? entry.NativeName
            : language.Code;

    private string DisplayBackend(TranscriptionBackendKind backend) => backend switch
    {
        TranscriptionBackendKind.Vulkan => window.ResourceText("BackendAccelerated"),
        _ => window.ResourceText("BackendCpu"),
    };

    private string InsertionStatus(
        TextInsertionOutcome outcome,
        LocalInferenceResult inference,
        ProcessedDictation processed,
        string warning)
    {
        var localEngine = window.ResourceFormat(
            "TranscribedLocally",
            DisplayLanguage(inference.LanguageDecision.Language),
            DisplayBackend(inference.Transcription.Backend));
        var insertionStatus = outcome.Kind switch
        {
            TextInsertionOutcomeKind.InsertedDirect => window.ResourceText("InsertionDirect"),
            TextInsertionOutcomeKind.InsertedByPaste when outcome.ClipboardRestored => window.ResourceText("InsertionPasteRestored"),
            TextInsertionOutcomeKind.InsertedByPaste => window.ResourceText("InsertionPasteRetained"),
            TextInsertionOutcomeKind.CopiedForRecovery => window.ResourceText("InsertionCopiedRecovery"),
            TextInsertionOutcomeKind.RefusedProtectedField => window.ResourceText("InsertionProtectedRefusal"),
            TextInsertionOutcomeKind.ClipboardProtectionFailed => window.ResourceText("InsertionClipboardFailed"),
            TextInsertionOutcomeKind.UnverifiedDirectWrite => window.ResourceText("InsertionUnverifiedDirect"),
            TextInsertionOutcomeKind.UnverifiedPaste => window.ResourceText("InsertionUnverifiedPaste"),
            TextInsertionOutcomeKind.Cancelled => window.ResourceText("InsertionCancelled"),
            _ => window.ResourceText("InsertionUnsafeTarget"),
        };
        var reviewStatus = processed.Review.DeservesAttention
            ? processed.Review.Flagged.Count == 1
                ? window.ResourceText("ReviewAttentionOneStatus")
                : window.ResourceFormat("ReviewAttentionManyStatus", processed.Review.Flagged.Count)
            : string.Empty;
        return string.Concat(localEngine, insertionStatus, reviewStatus, warning);
    }

    private string SafeError(Exception error) => error switch
    {
        TranscriptionBackendException backendError => backendError.FailureKind switch
        {
            TranscriptionBackendFailureKind.ResourceExhausted => window.ResourceText("TranscriptionMemoryError"),
            TranscriptionBackendFailureKind.Unavailable => window.ResourceText("TranscriptionBackendUnavailable"),
            _ => window.ResourceText("TranscriptionEngineError"),
        },
        NativeTranscriptionException nativeError when nativeError.Status == NativeTranscriptionStatus.OutOfMemory =>
            window.ResourceText("TranscriptionMemoryError"),
        _ => window.ResourceText("TranscriptionEngineError"),
    };
}
