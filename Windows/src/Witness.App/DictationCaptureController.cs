using System.Windows.Threading;
using Witness.Core.Input;
using Witness.Platform.Windows.Audio;
using Witness.Platform.Windows.Insertion;

namespace Witness.App;

internal sealed class DictationCaptureController(
    Dispatcher dispatcher,
    ActivityWindow activityWindow,
    MainWindow mainWindow,
    IInsertionTargetObserver? insertionTargets = null,
    Func<long>? beginOperation = null,
    Func<AudioCaptureResult, InsertionTarget?, long, Task<bool>>? completedCaptureProcessor = null) : IDisposable
{
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private AudioCaptureSession? session;
    private InsertionTarget? capturedTarget;
    private long operationGeneration;
    private bool disposed;
    private int statusGeneration;

    public void Handle(HotkeyAction action)
    {
        if (disposed || action == HotkeyAction.None) return;
        if (action == HotkeyAction.BeginRecording)
        {
            var generation = beginOperation?.Invoke() ?? 0;
            var observation = insertionTargets?.Observe();
            var target = observation?.DesktopAvailable == true ? observation.Target : null;
            _ = BeginAsync(generation, target);
        }
        else
        {
            _ = EndAsync();
        }
    }

    public void RequestStop() => _ = EndAsync();

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (!operationGate.Wait(0)) return;
        try
        {
            session?.Dispose();
            session = null;
            capturedTarget = null;
        }
        finally
        {
            operationGate.Release();
            operationGate.Dispose();
        }
    }

    private async Task BeginAsync(long generation, InsertionTarget? target)
    {
        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (disposed || session is not null) return;
            operationGeneration = generation;
            capturedTarget = target;
            await ShowAsync(ActivityVisualState.Processing, "Opening the selected microphone…").ConfigureAwait(false);
            var candidate = new AudioCaptureSession(
                new NativeAudioCapture(endpointId: null),
                new NativeAudioSampleProcessor());
            candidate.AutomaticStopRequested += AutomaticStopRequested;
            try
            {
                await Task.Run(candidate.Start).ConfigureAwait(false);
                session = candidate;
                await ShowAsync(ActivityVisualState.Listening).ConfigureAwait(false);
                await SetMainStatusAsync("Listening locally. Release any shortcut key to stop.").ConfigureAwait(false);
            }
            catch
            {
                candidate.AutomaticStopRequested -= AutomaticStopRequested;
                candidate.Dispose();
                throw;
            }
        }
        catch (NativeAudioException error)
        {
            capturedTarget = null;
            await ShowCaptureErrorAsync(error).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            capturedTarget = null;
            await ShowAsync(ActivityVisualState.Error, "No audio left this PC.").ConfigureAwait(false);
            await SetMainStatusAsync($"Microphone capture failed locally: {error.Message}").ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
        }
    }

    private async Task EndAsync()
    {
        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            var active = session;
            if (disposed || active is null) return;
            session = null;
            var target = capturedTarget;
            var generation = operationGeneration;
            capturedTarget = null;
            active.AutomaticStopRequested -= AutomaticStopRequested;
            await ShowAsync(ActivityVisualState.Processing, "Finishing the in-memory phrase…").ConfigureAwait(false);
            try
            {
                var result = await active.StopAsync().ConfigureAwait(false);
                try
                {
                    var handled = completedCaptureProcessor is not null
                        && await completedCaptureProcessor(result, target, generation).ConfigureAwait(false);
                    if (!handled)
                    {
                        await PresentResultAsync(result).ConfigureAwait(false);
                    }
                    else
                    {
                        _ = HideActivityAfterDelayAsync();
                    }
                }
                finally
                {
                    Array.Clear(result.Pcm16KhzMono);
                }
            }
            finally
            {
                active.Dispose();
            }
        }
        catch (NativeAudioException error)
        {
            await ShowCaptureErrorAsync(error).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            await ShowAsync(ActivityVisualState.Error, "The phrase was not persisted.").ConfigureAwait(false);
            await SetMainStatusAsync($"Audio processing failed locally: {error.Message}").ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
        }
    }

    private void AutomaticStopRequested(object? sender, EventArgs e) => _ = EndAsync();

    private async Task PresentResultAsync(AudioCaptureResult result)
    {
        switch (result.Kind)
        {
            case AudioCaptureCompletionKind.NoSpeech:
            case AudioCaptureCompletionKind.InterruptedWithoutSpeech:
                await ShowAsync(result.Kind == AudioCaptureCompletionKind.NoSpeech
                    ? ActivityVisualState.NoSpeech
                    : ActivityVisualState.Interrupted).ConfigureAwait(false);
                await SetMainStatusAsync(result.Kind == AudioCaptureCompletionKind.NoSpeech
                    ? "No speech was detected. No audio was saved."
                    : "The microphone was interrupted before speech was detected. No audio was saved.").ConfigureAwait(false);
                break;
            case AudioCaptureCompletionKind.InterruptedWithSpeech:
                await ShowAsync(ActivityVisualState.Interrupted, "Captured speech remains in memory for the next local stage.").ConfigureAwait(false);
                await SetMainStatusAsync("The microphone was interrupted. Captured speech stayed in memory; transcription is not connected in this preview.").ConfigureAwait(false);
                break;
            default:
                var warning = result.HadDiscontinuity || result.BufferOverflowed || result.DroppedPacketCount > 0
                    ? " A capture gap was detected and is reported explicitly."
                    : string.Empty;
                await ShowAsync(ActivityVisualState.Processing, "Capture complete; transcription is not connected in this preview.").ConfigureAwait(false);
                await SetMainStatusAsync($"Speech was captured and normalized locally, then released after this preview step.{warning}").ConfigureAwait(false);
                break;
        }
        _ = HideActivityAfterDelayAsync();
    }

    private async Task ShowCaptureErrorAsync(NativeAudioException error)
    {
        var message = error.Status switch
        {
            NativeAudioStatus.AudioAccessDenied => "Microphone access is off. Enable microphone access for desktop apps in Windows Settings.",
            NativeAudioStatus.AudioDeviceUnavailable => "No available microphone could be opened. Check the selected Windows input device.",
            NativeAudioStatus.AudioFormatUnsupported => "The microphone uses an unsupported audio format.",
            _ => error.Message,
        };
        await ShowAsync(ActivityVisualState.Error, message).ConfigureAwait(false);
        if (error.Status == NativeAudioStatus.AudioAccessDenied)
            await dispatcher.InvokeAsync(mainWindow.ShowMicrophoneAccessDenied);
        else
            await SetMainStatusAsync(message).ConfigureAwait(false);
        _ = HideActivityAfterDelayAsync();
    }

    private async Task HideActivityAfterDelayAsync()
    {
        var generation = Interlocked.Increment(ref statusGeneration);
        await Task.Delay(TimeSpan.FromSeconds(4)).ConfigureAwait(false);
        if (generation == Volatile.Read(ref statusGeneration) && !disposed)
            await ShowAsync(ActivityVisualState.Hidden).ConfigureAwait(false);
    }

    private async Task ShowAsync(ActivityVisualState state, string? detail = null)
    {
        Interlocked.Increment(ref statusGeneration);
        await dispatcher.InvokeAsync(() => activityWindow.ShowState(state, detail));
    }

    private async Task SetMainStatusAsync(string status) =>
        await dispatcher.InvokeAsync(() => mainWindow.SetStatus(status));
}
