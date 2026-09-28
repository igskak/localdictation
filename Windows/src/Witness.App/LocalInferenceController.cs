using System.Windows.Threading;
using Witness.Core.Languages;
using Witness.Core.Transcription;
using Witness.Platform.Windows.Audio;
using Witness.Platform.Windows.Transcription;

namespace Witness.App;

internal sealed class LocalInferenceController : IAsyncDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly MainWindow window;
    private readonly LocalInferencePipeline pipeline;
    private string? verifiedModelPath;
    private LanguageProfile? selectedProfile;
    private bool disposed;

    public LocalInferenceController(Dispatcher dispatcher, MainWindow window)
    {
        this.dispatcher = dispatcher;
        this.window = window;
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

    public async Task<bool> ProcessAsync(AudioCaptureResult capture)
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

        try
        {
            var result = await pipeline.ProcessAsync(new LocalInferenceRequest(
                capture.Pcm16KhzMono,
                modelPath,
                profile,
                PinnedLanguage: null,
                ThreadCount: Math.Clamp(Environment.ProcessorCount - 1, 1, 8))).ConfigureAwait(false);
            var warning = capture.Kind == AudioCaptureCompletionKind.InterruptedWithSpeech
                || capture.HadDiscontinuity
                || capture.BufferOverflowed
                || capture.DroppedPacketCount > 0
                ? " A capture interruption or gap was preserved as an explicit warning."
                : string.Empty;
            var status = string.IsNullOrWhiteSpace(result.Transcription.Transcript.Text)
                ? $"The local engine completed in {DisplayLanguage(result.LanguageDecision.Language)}, but returned no text; Witness did not substitute a polished result.{warning}"
                : $"Transcribed locally in {DisplayLanguage(result.LanguageDecision.Language)} using {DisplayBackend(result.Transcription.Backend)}. Text insertion is intentionally not enabled until W4.{warning}";
            await SetStatusAsync(status).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // A newer completed phrase or shutdown superseded this generation.
        }
        catch (Exception error)
        {
            await SetStatusAsync($"Local transcription failed without producing an insertion: {SafeError(error)}").ConfigureAwait(false);
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

    private static string DisplayLanguage(SpeechLanguage language) =>
        LanguageCatalog.ByCode.TryGetValue(language.Code, out var entry)
            ? entry.EnglishName
            : language.Code;

    private static string DisplayBackend(TranscriptionBackendKind backend) => backend switch
    {
        TranscriptionBackendKind.Vulkan => "the accelerated backend",
        _ => "the CPU backend",
    };

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
