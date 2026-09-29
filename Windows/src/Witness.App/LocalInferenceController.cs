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
    private readonly DictationPostProcessor postProcessor = new();
    private readonly RecentDictationHistory history = new();
    private readonly ReviewAudioLease reviewAudio = new();
    private readonly object resultGate = new();
    private string? verifiedModelPath;
    private LanguageProfile? selectedProfile;
    private ProcessedDictation? latestResult;
    private bool disposed;

    public LocalInferenceController(
        Dispatcher dispatcher,
        MainWindow window,
        TextInsertionCoordinator insertion,
        HotkeyModifiers hotkeyModifiers)
    {
        this.dispatcher = dispatcher;
        this.window = window;
        this.insertion = insertion;
        this.hotkeyModifiers = hotkeyModifiers;
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

    public long BeginOperation()
    {
        lock (resultGate)
        {
            pipeline.CancelActive();
            var generation = insertionGenerations.Supersede();
            reviewAudio.Release();
            latestResult = null;
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
            await SetStatusAsync("Choose a speech language profile before dictating. The captured audio was released.").ConfigureAwait(false);
            return true;
        }
        if (modelPath is null)
        {
            Array.Clear(capture.Pcm16KhzMono);
            await SetStatusAsync("Speech was captured, but the verified local model is not ready. Download or verify it above, then try again. The audio was released.").ConfigureAwait(false);
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
                ? " A capture interruption or gap was preserved as an explicit warning."
                : string.Empty;
            var processed = postProcessor.Process(
                result.Transcription.Transcript,
                result.LanguageDecision.Language,
                profile);
            if (string.IsNullOrWhiteSpace(processed.TextForInsertion))
            {
                lock (resultGate)
                {
                    if (!insertionGenerations.IsCurrent(generation))
                    {
                        return true;
                    }
                    reviewAudio.Replace(capture.Pcm16KhzMono, EngineSampleRate, processed);
                    latestResult = null;
                    completedAudioHandled = true;
                }
                await SetStatusAsync($"The local engine completed in {DisplayLanguage(result.LanguageDecision.Language)}, but returned no text; Witness did not substitute a polished result.{warning}", generation).ConfigureAwait(false);
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
                }
                else
                {
                    reviewAudio.Replace(capture.Pcm16KhzMono, EngineSampleRate, processed);
                    latestResult = processed;
                }
                completedAudioHandled = true;
            }
            var status = InsertionStatus(insertionResult, result, processed, warning);
            await SetStatusAsync(status, generation).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // A newer completed phrase or shutdown superseded this generation.
        }
        catch (Exception error)
        {
            await SetStatusAsync($"Local transcription failed without producing an insertion: {SafeError(error)}", generation).ConfigureAwait(false);
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
            latestResult = null;
            history.Clear();
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
        var status = progress.Stage switch
        {
            LocalInferenceStage.LoadingModel => "Loading the verified speech model locally…",
            LocalInferenceStage.DetectingLanguage => "Choosing a language from the selected profile after recording completed…",
            LocalInferenceStage.Transcribing => $"Transcribing locally in {DisplayLanguage(progress.Language!.Value)}…",
            _ => null,
        };
        if (status is not null)
        {
            dispatcher.BeginInvoke(() => window.SetStatus(status));
        }
    }

    private async Task SetStatusAsync(string status) =>
        await dispatcher.InvokeAsync(() => window.SetStatus(status));

    private async Task SetStatusAsync(string status, long generation) =>
        await dispatcher.InvokeAsync(() =>
        {
            if (insertionGenerations.IsCurrent(generation))
            {
                window.SetStatus(status);
            }
        });

    private static string DisplayLanguage(SpeechLanguage language) =>
        LanguageCatalog.ByCode.TryGetValue(language.Code, out var entry)
            ? entry.EnglishName
            : language.Code;

    private static string DisplayBackend(TranscriptionBackendKind backend) => backend switch
    {
        TranscriptionBackendKind.Vulkan => "the accelerated backend",
        _ => "the CPU backend",
    };

    private static string InsertionStatus(
        TextInsertionOutcome outcome,
        LocalInferenceResult inference,
        ProcessedDictation processed,
        string warning)
    {
        var localEngine = $"Transcribed locally in {DisplayLanguage(inference.LanguageDecision.Language)} using {DisplayBackend(inference.Transcription.Backend)}.";
        var insertionStatus = outcome.Kind switch
        {
            TextInsertionOutcomeKind.InsertedDirect => " Inserted into the verified text field without using the clipboard.",
            TextInsertionOutcomeKind.InsertedByPaste when outcome.ClipboardRestored => " Inserted once and restored the previous clipboard after exact verification.",
            TextInsertionOutcomeKind.InsertedByPaste => " Inserted once; the protected dictation clipboard was left unchanged because safe restoration was unavailable.",
            TextInsertionOutcomeKind.CopiedForRecovery => " The target changed or could not accept input, so the text remains on the protected clipboard for manual recovery.",
            TextInsertionOutcomeKind.RefusedProtectedField => " The focused field is protected; Witness did not insert or copy the text.",
            TextInsertionOutcomeKind.ClipboardProtectionFailed => " Witness could not verify a protected clipboard write; no unprotected fallback was attempted.",
            TextInsertionOutcomeKind.UnverifiedDirectWrite => " The direct write could not be verified, so Witness did not attempt a second insertion.",
            TextInsertionOutcomeKind.UnverifiedPaste => " One paste was sent but could not be verified; the protected dictation clipboard was left for recovery and no retry was attempted.",
            TextInsertionOutcomeKind.Cancelled => " A newer dictation superseded this result before insertion.",
            _ => " The target could not be verified safely; Witness retained the text without inserting or copying it.",
        };
        var reviewStatus = processed.Review.DeservesAttention
            ? processed.Review.Flagged.Count == 1
                ? " One fragment is worth checking."
                : $" {processed.Review.Flagged.Count} fragments are worth checking."
            : string.Empty;
        return string.Concat(localEngine, insertionStatus, reviewStatus, warning);
    }

    private static string SafeError(Exception error) => error switch
    {
        TranscriptionBackendException backendError => backendError.FailureKind switch
        {
            TranscriptionBackendFailureKind.ResourceExhausted => "not enough local memory was available.",
            TranscriptionBackendFailureKind.Unavailable => "the selected local speech backend was unavailable.",
            _ => "the local speech engine could not complete the phrase.",
        },
        NativeTranscriptionException nativeError when nativeError.Status == NativeTranscriptionStatus.OutOfMemory =>
            "not enough local memory was available.",
        _ => "the local speech engine could not complete the phrase.",
    };
}
