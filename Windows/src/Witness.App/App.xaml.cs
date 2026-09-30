using System.Diagnostics;
using System.IO;
using Witness.Core;
using Witness.Core.Audio;
using Witness.Core.Input;
using Witness.Core.Languages;
using Witness.Core.Licensing;
using Witness.Core.Recording;
using Witness.Core.Review;
using Witness.Core.Settings;
using Witness.Core.Telemetry;
using Witness.Platform.Windows.Audio;
using Witness.Platform.Windows.Licensing;
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
    private readonly SemaphoreSlim entitlementOperations = new(1, 1);
    private EntitlementSession? entitlementSession;
    private DeviceIdentityResult deviceIdentity = new(null, "Windows device identity has not been read.");
    private WindowsBetaLicenseConfiguration licenseConfiguration = WindowsBetaLicenseConfiguration.FromValues(null, null);
    private HttpClientActivationTransport? activationTransport;
    private string? entitlementError;
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
        ConfigureLicensing();
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
            inferenceController.ProcessAsync,
            CanBeginDictation,
            DictationBlockedByLicense);
        captureController.SetAudioInputSelection(preferences.AudioInput);

        WireWindow(window);
        modelSetupController.ModelReady += inferenceController.SetVerifiedModelPath;
        inferenceController.PrivacyStateChanged += InferencePrivacyStateChanged;
        inferenceController.SuccessfulDictationCompleted += SuccessfulDictationCompleted;

        trayIcon = new TrayIconService();
        trayIcon.OpenRequested += (_, _) => ShowMainWindow();
        trayIcon.ExitRequested += (_, _) => ExitApplication();
        ConfigureHotkey(window);
        ConfigureSessionMonitor(window);

        window.ApplyPreferences(preferences, ReadStartupEnabled(window));
        RefreshAudioInputs(window, preferences.AudioInput);
        RefreshGlossary(window);
        RefreshDiagnostics(window);
        RefreshLicense(window);
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
        {
            inferenceController.PrivacyStateChanged -= InferencePrivacyStateChanged;
            inferenceController.SuccessfulDictationCompleted -= SuccessfulDictationCompleted;
        }
        if (MainWindow is MainWindow window) UnwireWindow(window);
        inferenceController?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        insertionInspector?.Dispose();
        modelSetupController?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        activityWindow?.Close();
        activationTransport?.Dispose();
        entitlementOperations.Dispose();
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
        window.ProductEventSharingChanged += ChangeProductEventSharing;
        window.VoiceActivityConfigurationChanged += ChangeVoiceConfiguration;
        window.GlossaryTermAddRequested += AddGlossaryTerm;
        window.GlossaryTermRemoveRequested += RemoveGlossaryTerm;
        window.OnboardingLanguageSelectionConfirmed += ConfirmOnboardingLanguages;
        window.OnboardingCompleted += CompleteOnboarding;
        window.LicenseActivationRequested += RequestLicenseActivation;
        window.LicenseKeySubmitted += SubmitLicenseKey;
        window.LicenseRemovalRequested += RemoveLicense;
        window.LegalDocumentRequested += OpenLegalDocument;
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
        window.ProductEventSharingChanged -= ChangeProductEventSharing;
        window.VoiceActivityConfigurationChanged -= ChangeVoiceConfiguration;
        window.GlossaryTermAddRequested -= AddGlossaryTerm;
        window.GlossaryTermRemoveRequested -= RemoveGlossaryTerm;
        window.OnboardingLanguageSelectionConfirmed -= ConfirmOnboardingLanguages;
        window.OnboardingCompleted -= CompleteOnboarding;
        window.LicenseActivationRequested -= RequestLicenseActivation;
        window.LicenseKeySubmitted -= SubmitLicenseKey;
        window.LicenseRemovalRequested -= RemoveLicense;
        window.LegalDocumentRequested -= OpenLegalDocument;
    }

    private void ConfigureLicensing()
    {
        licenseConfiguration = WindowsBetaLicenseConfiguration.Current();
        try
        {
            deviceIdentity = new WindowsHardwareDeviceIdentity().Resolve();
        }
        catch (Exception error)
        {
            deviceIdentity = new DeviceIdentityResult(null, error.Message);
        }

        try
        {
            var backend = licenseConfiguration.CreateBackend(out activationTransport);
            entitlementSession = new EntitlementSession(
                new JsonEntitlementStore(JsonEntitlementStore.DefaultPath()),
                new LicenseKeyVerifier(),
                licenseConfiguration.Authority,
                deviceIdentity.DeviceId,
                ProductMetadata.Version,
                activationBackend: backend);
        }
        catch (Exception error)
        {
            entitlementSession = null;
            entitlementError = error.Message;
        }
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

    private void ChangeProductEventSharing(bool enabled)
    {
        preferences = preferences with { ProductEventSharingEnabled = enabled };
        SavePreferences();
    }

    private bool CanBeginDictation()
    {
        var session = entitlementSession;
        if (session is null) return false;
        if (!entitlementOperations.Wait(0)) return session.State.AllowsDictation;
        try
        {
            var state = session.Refresh();
            if (MainWindow is MainWindow window) RefreshLicense(window, state);
            return state.AllowsDictation;
        }
        catch (Exception error)
        {
            entitlementError = error.Message;
            if (MainWindow is MainWindow window) RefreshLicense(window);
            return false;
        }
        finally
        {
            entitlementOperations.Release();
        }
    }

    private void DictationBlockedByLicense()
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (MainWindow is not MainWindow window) return;
            var state = entitlementSession?.State;
            if (state?.Lock is EntitlementLock entitlementLock)
            {
                entitlementSession?.RecordPaywallShown(PaywallTriggerFor(entitlementLock));
            }
            RefreshLicense(window, state);
            window.SetStatus(window.ResourceText("LicenseLockedStatus"));
            window.OpenLicenseSection();
            ShowMainWindow();
        });
    }

    private void SuccessfulDictationCompleted(object? sender, EventArgs e) =>
        _ = RecordSuccessfulDictationAsync();

    private async Task RecordSuccessfulDictationAsync()
    {
        await entitlementOperations.WaitAsync().ConfigureAwait(false);
        try
        {
            entitlementSession?.RecordSuccessfulDictation();
        }
        catch (Exception error)
        {
            entitlementError = error.Message;
        }
        finally
        {
            entitlementOperations.Release();
        }
        await Dispatcher.InvokeAsync(() =>
        {
            if (MainWindow is MainWindow window) RefreshLicense(window);
        });
    }

    private async void RequestLicenseActivation(string email)
    {
        if (MainWindow is not MainWindow window || entitlementSession is null) return;
        window.SetLicenseBusy(true);
        await entitlementOperations.WaitAsync();
        try
        {
            await entitlementSession.RequestActivationAsync(email);
            entitlementError = null;
            window.ClearLicenseInputs();
            window.ShowLicenseNotice(window.ResourceText("LicenseActivationSucceeded"));
        }
        catch (ActivationException error)
        {
            window.ShowLicenseNotice(ActivationErrorMessage(window, error.Kind));
        }
        catch (Exception error)
        {
            entitlementError = error.Message;
            window.ShowLicenseNotice(window.ResourceFormat("LicenseStorageError", error.Message));
        }
        finally
        {
            entitlementOperations.Release();
            RefreshLicense(window);
            window.SetLicenseBusy(false);
        }
    }

    private async void SubmitLicenseKey(string token)
    {
        if (MainWindow is not MainWindow window || entitlementSession is null) return;
        window.SetLicenseBusy(true);
        await entitlementOperations.WaitAsync();
        try
        {
            entitlementSession.AcceptLicense(token);
            entitlementError = null;
            window.ClearLicenseInputs();
            window.ShowLicenseNotice(window.ResourceText("LicenseKeyAccepted"));
        }
        catch (LicenseKeyVerificationException error)
        {
            window.ShowLicenseNotice(LicenseErrorMessage(window, error.Kind));
        }
        catch (Exception error)
        {
            entitlementError = error.Message;
            window.ShowLicenseNotice(window.ResourceFormat("LicenseStorageError", error.Message));
        }
        finally
        {
            entitlementOperations.Release();
            RefreshLicense(window);
            window.SetLicenseBusy(false);
        }
    }

    private async void RemoveLicense(object? sender, EventArgs e)
    {
        if (MainWindow is not MainWindow window || entitlementSession is null) return;
        window.SetLicenseBusy(true);
        await entitlementOperations.WaitAsync();
        try
        {
            var outcome = await entitlementSession.ReleaseFromThisComputerAsync();
            entitlementError = null;
            var message = outcome.Kind switch
            {
                DeviceReleaseOutcomeKind.ReleasedEverywhere => window.ResourceText("LicenseRemovedEverywhere"),
                DeviceReleaseOutcomeKind.RemovedLocally => window.ResourceText("LicenseRemovedLocally"),
                _ => window.ResourceFormat("LicenseRemovedLocallyOnly", outcome.Warning ?? window.ResourceText("LicenseServiceUnavailable")),
            };
            window.ShowLicenseNotice(message);
        }
        catch (Exception error)
        {
            entitlementError = error.Message;
            window.ShowLicenseNotice(window.ResourceFormat("LicenseStorageError", error.Message));
        }
        finally
        {
            entitlementOperations.Release();
            RefreshLicense(window);
            window.SetLicenseBusy(false);
        }
    }

    private void RefreshLicense(MainWindow window, EntitlementState? state = null)
    {
        state ??= entitlementSession?.State ?? EntitlementState.Locked(EntitlementLock.ActivationRequired);
        window.ShowLicense(new LicenseScreenState(
            state,
            entitlementSession is null ? null : deviceIdentity.DeviceId,
            entitlementError ?? deviceIdentity.Error,
            entitlementSession is not null && licenseConfiguration.Authority.IsConfigured,
            entitlementSession?.CanRequestActivation == true,
            entitlementSession?.HasStoredLicenseToken == true));
    }

    private void OpenLegalDocument(LegalDocumentKind kind)
    {
        if (MainWindow is not MainWindow window) return;
        var fileName = kind == LegalDocumentKind.Privacy
            ? "WINDOWS_BETA_PRIVACY.md"
            : "WINDOWS_BETA_TERMS.md";
        var path = Path.Combine(AppContext.BaseDirectory, "Legal", fileName);
        if (!File.Exists(path))
        {
            window.ShowLicenseNotice(window.ResourceFormat("LegalDocumentMissing", fileName));
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception error)
        {
            window.ShowLicenseNotice(window.ResourceFormat("LegalDocumentOpenFailed", error.Message));
        }
    }

    private static PaywallTrigger PaywallTriggerFor(EntitlementLock entitlementLock) => entitlementLock.Kind switch
    {
        EntitlementLockKind.ActivationRequired => PaywallTrigger.ActivationRequired,
        EntitlementLockKind.ExpiredTrial => PaywallTrigger.TrialExpired,
        EntitlementLockKind.ExpiredAnnual => PaywallTrigger.LicenseExpired,
        _ => PaywallTrigger.UpdateRequired,
    };

    private static string ActivationErrorMessage(MainWindow window, ActivationErrorKind kind) => window.ResourceText(kind switch
    {
        ActivationErrorKind.NotConfigured => "LicenseActivationNotConfigured",
        ActivationErrorKind.DeviceIdentityUnavailable => "LicenseDeviceUnavailable",
        ActivationErrorKind.InvalidEmail => "LicenseInvalidEmail",
        ActivationErrorKind.Unreachable => "LicenseServiceUnavailable",
        ActivationErrorKind.DeviceLimitReached => "LicenseDeviceLimit",
        _ => "LicenseActivationRejected",
    });

    private static string LicenseErrorMessage(MainWindow window, LicenseKeyErrorKind kind) => window.ResourceText(kind switch
    {
        LicenseKeyErrorKind.Malformed => "LicenseMalformed",
        LicenseKeyErrorKind.UnsupportedVersion => "LicenseUnsupported",
        LicenseKeyErrorKind.NoAuthority => "LicenseNoAuthority",
        LicenseKeyErrorKind.DeviceIdentityUnavailable => "LicenseDeviceUnavailable",
        LicenseKeyErrorKind.BadSignature => "LicenseBadSignature",
        LicenseKeyErrorKind.WrongDevice => "LicenseWrongDevice",
        _ => "LicenseBadDates",
    });

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
