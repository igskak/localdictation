using System.Windows.Threading;
using Witness.Core.Audio;
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
    Func<AudioCaptureResult, InsertionTarget?, long, Task<bool>>? completedCaptureProcessor = null,
    Func<bool>? canBeginRecording = null,
    Action? recordingBlocked = null,
    SilentBluetoothEndpointMemory? silentBluetoothMemory = null) : IDisposable
{
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private AudioInputSelection audioInputSelection = AudioInputSelection.SystemDefault;
    private VoiceActivityConfiguration voiceConfiguration = VoiceActivityConfiguration.Default;
    private AudioCaptureSession? session;
    private AudioInputDevice? activeInputDevice;
    private InsertionTarget? capturedTarget;
    private long operationGeneration;
    private bool disposed;
    private int statusGeneration;
    private readonly SilentBluetoothEndpointMemory silentBluetooth = silentBluetoothMemory ?? new();

    internal bool IsBusy => Volatile.Read(ref session) is not null || operationGate.CurrentCount == 0;

    internal void SetAudioInputSelection(AudioInputSelection selection) =>
        Volatile.Write(ref audioInputSelection, selection ?? throw new ArgumentNullException(nameof(selection)));

    internal void SetVoiceActivityConfiguration(VoiceActivityConfiguration configuration) =>
        Volatile.Write(ref voiceConfiguration, (configuration ?? throw new ArgumentNullException(nameof(configuration))).Validated());

    public void Handle(HotkeyAction action)
    {
        if (disposed || action == HotkeyAction.None) return;
        if (action == HotkeyAction.BeginRecording)
        {
            if (canBeginRecording is not null && !canBeginRecording())
            {
                recordingBlocked?.Invoke();
                return;
            }
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
            activeInputDevice = null;
            await ShowResourceAsync(ActivityVisualState.Processing, "OpeningMicrophone").ConfigureAwait(false);
            var selection = Volatile.Read(ref audioInputSelection);
            var configuration = Volatile.Read(ref voiceConfiguration);
            string? endpointId = null;
            AudioInputResolution? resolution = null;
            var devices = NativeAudioDeviceEnumerator.GetActiveInputs();
            resolution = SilentBluetoothFallbackPolicy.Resolve(selection, devices, silentBluetooth);
            if (resolution.Device is null)
            {
                throw new NativeAudioException(
                    NativeAudioStatus.AudioDeviceUnavailable,
                    "No active Windows microphone is available.");
            }
            if (selection.Kind != AudioInputSelectionKind.SystemDefault || !resolution.Device.IsSystemDefault)
                endpointId = resolution.Device.Id;
            activeInputDevice = resolution.Device;
            var routeMonitor = selection.Kind == AudioInputSelectionKind.SystemDefault
                ? new AudioEndpointNotificationMonitor()
                : null;
            var candidate = new AudioCaptureSession(
                new NativeAudioCapture(endpointId),
                new NativeAudioSampleProcessor(),
                configuration,
                new NativeAudioCaptureFactory(endpointId),
                routeMonitor);
            candidate.AutomaticStopRequested += AutomaticStopRequested;
            try
            {
                await Task.Run(candidate.Start).ConfigureAwait(false);
                session = candidate;
                await ShowAsync(ActivityVisualState.Listening).ConfigureAwait(false);
                var fallback = resolution?.UsedFallback == true
                    ? await ResourceTextAsync("MicrophoneFallback").ConfigureAwait(false)
                    : string.Empty;
                await SetMainStatusResourceAsync("ListeningLocal", fallback).ConfigureAwait(false);
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
            activeInputDevice = null;
            await ShowCaptureErrorAsync(error).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            capturedTarget = null;
            activeInputDevice = null;
            await ShowResourceAsync(ActivityVisualState.Error, "NoAudioLeftPc").ConfigureAwait(false);
            await SetMainStatusResourceAsync("MicrophoneCaptureFailed", error.Message).ConfigureAwait(false);
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
            var inputDevice = activeInputDevice;
            var generation = operationGeneration;
            capturedTarget = null;
            activeInputDevice = null;
            active.AutomaticStopRequested -= AutomaticStopRequested;
            await ShowResourceAsync(ActivityVisualState.Processing, "FinishingPhrase").ConfigureAwait(false);
            try
            {
                var result = await active.StopAsync().ConfigureAwait(false);
                try
                {
                    if (result.DeliveredOnlyExactZero && inputDevice is not null)
                        silentBluetooth.RememberSilent(inputDevice);
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
            await ShowResourceAsync(ActivityVisualState.Error, "PhraseNotPersisted").ConfigureAwait(false);
            await SetMainStatusResourceAsync("AudioProcessingFailed", error.Message).ConfigureAwait(false);
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
                await SetMainStatusResourceAsync(result.Kind == AudioCaptureCompletionKind.NoSpeech
                    ? "NoSpeechSaved"
                    : "InterruptedBeforeSpeech").ConfigureAwait(false);
                break;
            case AudioCaptureCompletionKind.InterruptedWithSpeech:
                await ShowResourceAsync(ActivityVisualState.Interrupted, "InterruptedSpeechMemory").ConfigureAwait(false);
                await SetMainStatusResourceAsync("InterruptedPreview").ConfigureAwait(false);
                break;
            default:
                var warning = result.HadDiscontinuity || result.BufferOverflowed || result.DroppedPacketCount > 0
                    ? await ResourceTextAsync("CaptureGapWarning").ConfigureAwait(false)
                    : string.Empty;
                await ShowResourceAsync(ActivityVisualState.Processing, "CapturePreviewComplete").ConfigureAwait(false);
                await SetMainStatusResourceAsync("CaptureReleased", warning).ConfigureAwait(false);
                break;
        }
        _ = HideActivityAfterDelayAsync();
    }

    private async Task ShowCaptureErrorAsync(NativeAudioException error)
    {
        var resourceKey = error.Status switch
        {
            NativeAudioStatus.AudioAccessDenied => "MicrophoneAccessError",
            NativeAudioStatus.AudioDeviceUnavailable => "MicrophoneUnavailableError",
            NativeAudioStatus.AudioFormatUnsupported => "MicrophoneFormatError",
            _ => null,
        };
        if (resourceKey is null)
            await ShowAsync(ActivityVisualState.Error, error.Message).ConfigureAwait(false);
        else
            await ShowResourceAsync(ActivityVisualState.Error, resourceKey).ConfigureAwait(false);
        if (error.Status == NativeAudioStatus.AudioAccessDenied)
            await dispatcher.InvokeAsync(mainWindow.ShowMicrophoneAccessDenied);
        else if (resourceKey is not null)
            await SetMainStatusResourceAsync(resourceKey).ConfigureAwait(false);
        else
            await SetMainStatusAsync(error.Message).ConfigureAwait(false);
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

    private async Task ShowResourceAsync(ActivityVisualState state, string key, params object[] arguments)
    {
        Interlocked.Increment(ref statusGeneration);
        await dispatcher.InvokeAsync(() =>
            activityWindow.ShowState(state, mainWindow.ResourceFormat(key, arguments)));
    }

    private async Task<string> ResourceTextAsync(string key) =>
        await dispatcher.InvokeAsync(() => mainWindow.ResourceText(key));

    private async Task SetMainStatusResourceAsync(string key, params object[] arguments) =>
        await dispatcher.InvokeAsync(() => mainWindow.SetStatus(mainWindow.ResourceFormat(key, arguments)));

    private async Task SetMainStatusAsync(string status) =>
        await dispatcher.InvokeAsync(() => mainWindow.SetStatus(status));
}
