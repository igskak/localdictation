using System.Diagnostics;
using Witness.Core.Audio;
using Witness.Core.Input;
using Witness.Core.Languages;
using Witness.Core.Review;
using Witness.Core.Settings;
using Witness.Platform.Windows.Audio;
using Witness.Platform.Windows.Settings;
using Witness.Platform.Windows.Startup;

namespace Witness.App;

public partial class App : System.Windows.Application
{
    private readonly HotkeyChord dictationHotkey = new(
        HotkeyModifiers.Control | HotkeyModifiers.Shift,
        0x20);
    private TrayIconService? trayIcon;
    private ActivityWindow? activityWindow;
    private Witness.Platform.Windows.Hotkeys.GlobalHotkeyService? hotkeyService;
    private HotkeyGestureStateMachine? hotkeyGesture;
    private DictationCaptureController? captureController;
    private Witness.Platform.Windows.Lifecycle.DesktopSessionMonitor? sessionMonitor;
    private ModelSetupController? modelSetupController;
    private LocalInferenceController? inferenceController;
    private Witness.Platform.Windows.Insertion.UiAutomationProtectionInspector? insertionInspector;
    private Witness.Platform.Windows.Insertion.ProtectedClipboardService? protectedClipboard;
    private IUserPreferencesStore? preferencesStore;
    private RunAtStartupService? startupService;
    private UserPreferences preferences = UserPreferences.Default;
    private bool isExplicitExit;

    protected override void OnStartup(System.Windows.StartupEventArgs e)
    {
        base.OnStartup(e);
        LocalizationResources.UseCurrentCulture(Resources);
        ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown;

        preferencesStore = new JsonUserPreferencesStore(JsonUserPreferencesStore.DefaultPath());
        var load = preferencesStore.Load();
        preferences = load.Preferences.Normalized();
        startupService = BuildStartupService();

        var window = new MainWindow();
        MainWindow = window;
        window.Closing += (_, eventArgs) =>
        {
            if (isExplicitExit) return;
            eventArgs.Cancel = true;
            window.Hide();
        };
        activityWindow = new ActivityWindow();
        modelSetupController = new ModelSetupController(Dispatcher, window);
        var windowHandle = new System.Windows.Interop.WindowInteropHelper(window).EnsureHandle();
        var insertionTargets = new Witness.Platform.Windows.Insertion.ForegroundInsertionTargetService();
        insertionInspector = new Witness.Platform.Windows.Insertion.UiAutomationProtectionInspector();
        protectedClipboard = new Witness.Platform.Windows.Insertion.ProtectedClipboardService(windowHandle);
        var insertionCoordinator = new Witness.Platform.Windows.Insertion.TextInsertionCoordinator(
            insertionTargets,
            insertionInspector,
            new Witness.Platform.Windows.Insertion.StandardEditInsertionService(),
            protectedClipboard,
            new Witness.Platform.Windows.Insertion.PasteInputService(),
            new Witness.Platform.Windows.Insertion.SystemInsertionDelay());
        inferenceController = new LocalInferenceController(
            Dispatcher,
            window,
            insertionCoordinator,
            dictationHotkey.Modifiers,
            new Witness.Platform.Windows.Review.WaveAudioFragmentPlayer());
        inferenceController.SetLanguageProfile(preferences.LanguageProfile());

        captureController = new DictationCaptureController(
            Dispatcher,
            activityWindow,
            window,
            insertionTargets,
            inferenceController.BeginOperation,
            inferenceController.ProcessAsync);
        captureController.SetAudioInputSelection(preferences.AudioInput);

        WireWindow(window);
        modelSetupController.ModelReady += inferenceController.SetVerifiedModelPath;
        inferenceController.PrivacyStateChanged += InferencePrivacyStateChanged;

        trayIcon = new TrayIconService();
        trayIcon.OpenRequested += (_, _) => ShowMainWindow();
        trayIcon.ExitRequested += (_, _) => ExitApplication();
        ConfigureHotkey(window);
        ConfigureSessionMonitor(window);

        window.ApplyPreferences(preferences, ReadStartupEnabled(window));
        RefreshAudioInputs(window, preferences.AudioInput);
        RefreshGlossary(window);
        RefreshDiagnostics(window);
        if (load.RecoveredFromInvalidData)
            window.SetStatus(window.ResourceText("SettingsRecovered"));
        window.Show();
        _ = modelSetupController.InspectAsync();
    }

    protected override void OnExit(System.Windows.ExitEventArgs e)
    {
        trayIcon?.Dispose();
        hotkeyService?.Dispose();
        sessionMonitor?.Dispose();
        captureController?.Dispose();
        if (modelSetupController is not null && inferenceController is not null)
            modelSetupController.ModelReady -= inferenceController.SetVerifiedModelPath;
        if (inferenceController is not null)
            inferenceController.PrivacyStateChanged -= InferencePrivacyStateChanged;
        if (MainWindow is MainWindow window) UnwireWindow(window);
        inferenceController?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        insertionInspector?.Dispose();
        modelSetupController?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        activityWindow?.Close();
        base.OnExit(e);
    }

    private void WireWindow(MainWindow window)
    {
        window.ReviewDismissed += DismissReview;
        window.ProtectedCopyRequested += CopyProtectedText;
        window.ReviewReplayRequested += ReplayReviewFragment;
        window.LanguageProfileChanged += ChangeLanguageProfile;
        window.ActivationModeChanged += ChangeActivationMode;
        window.LaunchAtStartupChanged += ChangeLaunchAtStartup;
        window.AudioInputChanged += ChangeAudioInput;
        window.VoiceActivityConfigurationChanged += ChangeVoiceConfiguration;
        window.GlossaryTermAddRequested += AddGlossaryTerm;
        window.GlossaryTermRemoveRequested += RemoveGlossaryTerm;
        window.OnboardingLanguageSelectionConfirmed += ConfirmOnboardingLanguages;
        window.OnboardingCompleted += CompleteOnboarding;
    }

    private void UnwireWindow(MainWindow window)
    {
        window.ReviewDismissed -= DismissReview;
        window.ProtectedCopyRequested -= CopyProtectedText;
        window.ReviewReplayRequested -= ReplayReviewFragment;
        window.LanguageProfileChanged -= ChangeLanguageProfile;
        window.ActivationModeChanged -= ChangeActivationMode;
        window.LaunchAtStartupChanged -= ChangeLaunchAtStartup;
        window.AudioInputChanged -= ChangeAudioInput;
        window.VoiceActivityConfigurationChanged -= ChangeVoiceConfiguration;
        window.GlossaryTermAddRequested -= AddGlossaryTerm;
        window.GlossaryTermRemoveRequested -= RemoveGlossaryTerm;
        window.OnboardingLanguageSelectionConfirmed -= ConfirmOnboardingLanguages;
        window.OnboardingCompleted -= CompleteOnboarding;
    }

    private static RunAtStartupService? BuildStartupService()
    {
        var executablePath = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName;
        return string.IsNullOrWhiteSpace(executablePath)
            ? null
            : new RunAtStartupService(new CurrentUserRunValueStore(), "Witness", executablePath);
    }

    private void ShowMainWindow()
    {
        if (MainWindow is null) return;
        MainWindow.Show();
        if (MainWindow.WindowState == System.Windows.WindowState.Minimized)
            MainWindow.WindowState = System.Windows.WindowState.Normal;
        MainWindow.Activate();
    }

    private void DismissReview(object? sender, EventArgs eventArgs) => inferenceController?.DismissReview();

    private void CopyProtectedText(string text)
    {
        if (MainWindow is not MainWindow window || protectedClipboard is null) return;
        var write = protectedClipboard.TryWrite(text);
        window.SetStatus(write.Succeeded
            ? window.ResourceText("ClipboardProtectedSuccess")
            : window.ResourceText("ClipboardProtectedFailure"));
    }

    private void ReplayReviewFragment(RiskSpan span)
    {
        if (MainWindow is not MainWindow window || inferenceController is null) return;
        if (!inferenceController.Replay(span))
            window.SetStatus(window.ResourceText("ReplayUnavailable"));
    }

    private void ChangeLanguageProfile(LanguageProfile profile)
    {
        preferences = preferences with { LanguageCodes = profile.Languages.Select(language => language.Code).ToArray() };
        inferenceController?.SetLanguageProfile(profile);
        SavePreferences();
        if (MainWindow is MainWindow window) RefreshDiagnostics(window);
    }

    private void ConfirmOnboardingLanguages(LanguageProfile profile) => ChangeLanguageProfile(profile);

    private void CompleteOnboarding(object? sender, EventArgs e)
    {
        preferences = preferences with { OnboardingCompleted = true };
        SavePreferences();
        if (MainWindow is MainWindow window)
            window.SetStatus(window.ResourceText("SetupComplete"));
    }

    private void ChangeActivationMode(HotkeyActivationMode mode)
    {
        var action = hotkeyGesture?.ChangeMode(mode) ?? HotkeyAction.None;
        captureController?.Handle(action);
        preferences = preferences with { ActivationMode = mode };
        SavePreferences();
    }

    private void ChangeLaunchAtStartup(bool enabled)
    {
        if (MainWindow is not MainWindow window) return;
        try
        {
            if (startupService is null) throw new InvalidOperationException(window.ResourceText("ExecutablePathUnavailable"));
            startupService.SetEnabled(enabled);
            window.SetStatus(enabled
                ? window.ResourceText("StartupEnabled")
                : window.ResourceText("StartupDisabled"));
        }
        catch (Exception error)
        {
            window.SetStatus(window.ResourceFormat("StartupChangeError", error.Message));
            window.SetLaunchAtStartup(ReadStartupEnabled(window));
        }
    }

    private bool ReadStartupEnabled(MainWindow window)
    {
        try
        {
            return startupService?.IsEnabled == true;
        }
        catch (Exception error)
        {
            window.SetStatus(window.ResourceFormat("StartupReadError", error.Message));
            return false;
        }
    }

    private void ChangeAudioInput(AudioInputSelection selection)
    {
        preferences = preferences with { AudioInput = selection };
        captureController?.SetAudioInputSelection(selection);
        SavePreferences();
        if (MainWindow is MainWindow window)
        {
            RefreshAudioInputs(window, selection);
            RefreshDiagnostics(window);
        }
    }

    private void ChangeVoiceConfiguration(VoiceActivityConfiguration configuration) =>
        captureController?.SetVoiceActivityConfiguration(configuration);

    private void AddGlossaryTerm(string term, SpeechLanguage language)
    {
        if (MainWindow is not MainWindow window || inferenceController is null) return;
        var result = inferenceController.AddGlossaryTerm(term, language);
        var status = result switch
        {
            SessionGlossaryAddResult.Added => window.ResourceText("GlossaryAdded"),
            SessionGlossaryAddResult.Empty => window.ResourceText("GlossaryEmpty"),
            SessionGlossaryAddResult.TooLong => window.ResourceFormat("GlossaryTooLong", SessionGlossary.MaximumTermGraphemes),
            SessionGlossaryAddResult.Duplicate => window.ResourceText("GlossaryDuplicate"),
            SessionGlossaryAddResult.Full => window.ResourceFormat("GlossaryFull", SessionGlossary.MaximumEntries),
            _ => window.ResourceText("GlossaryLanguageNotSelected"),
        };
        if (result == SessionGlossaryAddResult.Added) window.ClearGlossaryTermInput();
        RefreshGlossary(window, status);
        RefreshDiagnostics(window);
    }

    private void RemoveGlossaryTerm(GlossaryEntry entry)
    {
        if (MainWindow is not MainWindow window || inferenceController is null) return;
        inferenceController.RemoveGlossaryTerm(entry);
        RefreshGlossary(window, window.ResourceText("GlossaryRemoved"));
        RefreshDiagnostics(window);
    }

    private void RefreshAudioInputs(MainWindow window, AudioInputSelection selection)
    {
        try
        {
            window.ShowAudioInputs(NativeAudioDeviceEnumerator.GetActiveInputs(), selection);
        }
        catch (Exception error)
        {
            window.ShowAudioInputs([], selection, window.ResourceFormat("MicrophoneEnumerationError", error.Message));
        }
    }

    private void RefreshGlossary(MainWindow window, string? status = null) =>
        window.ShowGlossary(inferenceController?.GlossaryEntries ?? [], status);

    private void RefreshDiagnostics(MainWindow window)
    {
        var controller = inferenceController;
        window.ShowDiagnostics(
            preferences.LanguageProfile(),
            controller?.GlossaryEntries.Count ?? 0,
            controller?.RecentDictations.Count ?? 0,
            controller?.HasRetainedReviewAudio == true,
            controller?.LexiconCapabilities ?? []);
    }

    private void InferencePrivacyStateChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(() =>
        {
            if (MainWindow is MainWindow window) RefreshDiagnostics(window);
        });

    private void SavePreferences()
    {
        try
        {
            preferences = preferences.Normalized();
            preferencesStore?.Save(preferences);
        }
        catch (Exception error)
        {
            if (MainWindow is MainWindow window)
                window.SetStatus(window.ResourceFormat("SettingsSaveError", error.Message));
        }
    }

    private void ExitApplication()
    {
        isExplicitExit = true;
        MainWindow?.Close();
        Shutdown();
    }

    private void ConfigureHotkey(MainWindow window)
    {
        try
        {
            var gesture = new HotkeyGestureStateMachine(preferences.ActivationMode);
            hotkeyGesture = gesture;
            hotkeyService = new Witness.Platform.Windows.Hotkeys.GlobalHotkeyService();
            hotkeyService.Pressed += (_, _) => captureController?.Handle(gesture.Press());
            hotkeyService.Released += (_, _) => captureController?.Handle(gesture.Release());
            var result = hotkeyService.Change(dictationHotkey);
            if (result.Status == Witness.Platform.Windows.Hotkeys.HotkeyRegistrationStatus.Conflict)
                window.SetStatus(window.ResourceText("HotkeyConflict"));
        }
        catch (Exception error)
        {
            hotkeyService?.Dispose();
            hotkeyService = null;
            window.SetStatus(window.ResourceFormat("HotkeyError", error.Message));
        }
    }

    private void ConfigureSessionMonitor(MainWindow window)
    {
        try
        {
            sessionMonitor = new Witness.Platform.Windows.Lifecycle.DesktopSessionMonitor(window);
            sessionMonitor.CaptureShouldStop += (_, _) => captureController?.RequestStop();
        }
        catch (Exception error)
        {
            window.SetStatus(window.ResourceFormat("SessionMonitorError", error.Message));
        }
    }
}
