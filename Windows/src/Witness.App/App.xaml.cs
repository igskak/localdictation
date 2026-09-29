namespace Witness.App;

public partial class App : System.Windows.Application
{
    private readonly Witness.Core.Input.HotkeyChord dictationHotkey = new(
        Witness.Core.Input.HotkeyModifiers.Control | Witness.Core.Input.HotkeyModifiers.Shift,
        0x20);
    private TrayIconService? trayIcon;
    private ActivityWindow? activityWindow;
    private Witness.Platform.Windows.Hotkeys.GlobalHotkeyService? hotkeyService;
    private DictationCaptureController? captureController;
    private Witness.Platform.Windows.Lifecycle.DesktopSessionMonitor? sessionMonitor;
    private ModelSetupController? modelSetupController;
    private LocalInferenceController? inferenceController;
    private Witness.Platform.Windows.Insertion.UiAutomationProtectionInspector? insertionInspector;
    private Witness.Platform.Windows.Insertion.ProtectedClipboardService? protectedClipboard;
    private bool isExplicitExit;

    protected override void OnStartup(System.Windows.StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown;
        MainWindow = new MainWindow();
        MainWindow.Closing += (_, eventArgs) =>
        {
            if (isExplicitExit) return;
            eventArgs.Cancel = true;
            MainWindow.Hide();
        };
        activityWindow = new ActivityWindow();
        modelSetupController = new ModelSetupController(Dispatcher, (MainWindow)MainWindow);
        var windowHandle = new System.Windows.Interop.WindowInteropHelper(MainWindow).EnsureHandle();
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
            (MainWindow)MainWindow,
            insertionCoordinator,
            dictationHotkey.Modifiers,
            new Witness.Platform.Windows.Review.WaveAudioFragmentPlayer());
        ((MainWindow)MainWindow).ReviewDismissed += DismissReview;
        ((MainWindow)MainWindow).ProtectedCopyRequested += CopyProtectedText;
        ((MainWindow)MainWindow).ReviewReplayRequested += ReplayReviewFragment;
        modelSetupController.ModelReady += inferenceController.SetVerifiedModelPath;
        ((MainWindow)MainWindow).LanguageProfileChanged += inferenceController.SetLanguageProfile;
        captureController = new DictationCaptureController(
            Dispatcher,
            activityWindow,
            (MainWindow)MainWindow,
            insertionTargets,
            inferenceController.BeginOperation,
            inferenceController.ProcessAsync);
        trayIcon = new TrayIconService();
        trayIcon.OpenRequested += (_, _) => ShowMainWindow();
        trayIcon.ExitRequested += (_, _) => ExitApplication();
        ConfigureHotkey((MainWindow)MainWindow);
        ConfigureSessionMonitor((MainWindow)MainWindow);
        MainWindow.Show();
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
        if (MainWindow is MainWindow window && inferenceController is not null)
        {
            window.LanguageProfileChanged -= inferenceController.SetLanguageProfile;
            window.ReviewDismissed -= DismissReview;
            window.ProtectedCopyRequested -= CopyProtectedText;
            window.ReviewReplayRequested -= ReplayReviewFragment;
        }
        inferenceController?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        insertionInspector?.Dispose();
        modelSetupController?.DisposeAsync().AsTask().GetAwaiter().GetResult();
        activityWindow?.Close();
        base.OnExit(e);
    }

    private void ShowMainWindow()
    {
        if (MainWindow is null) return;
        MainWindow.Show();
        if (MainWindow.WindowState == System.Windows.WindowState.Minimized)
            MainWindow.WindowState = System.Windows.WindowState.Normal;
        MainWindow.Activate();
    }

    private void DismissReview(object? sender, EventArgs eventArgs) =>
        inferenceController?.DismissReview();

    private void CopyProtectedText(string text)
    {
        if (MainWindow is not MainWindow window || protectedClipboard is null)
        {
            return;
        }
        var write = protectedClipboard.TryWrite(text);
        window.SetStatus(write.Succeeded
            ? "Copied with Windows clipboard history, Cloud Clipboard, and monitor processing disabled."
            : "Witness could not verify a protected clipboard write; no unprotected fallback was attempted.");
    }

    private void ReplayReviewFragment(Witness.Core.Review.RiskSpan span)
    {
        if (MainWindow is not MainWindow window || inferenceController is null)
        {
            return;
        }
        if (!inferenceController.Replay(span))
        {
            window.SetStatus("The in-memory review fragment is no longer available for replay.");
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
            var gesture = new Witness.Core.Input.HotkeyGestureStateMachine(Witness.Core.Input.HotkeyActivationMode.Hold);
            hotkeyService = new Witness.Platform.Windows.Hotkeys.GlobalHotkeyService();
            hotkeyService.Pressed += (_, _) => captureController?.Handle(gesture.Press());
            hotkeyService.Released += (_, _) => captureController?.Handle(gesture.Release());
            var result = hotkeyService.Change(dictationHotkey);
            if (result.Status == Witness.Platform.Windows.Hotkeys.HotkeyRegistrationStatus.Conflict)
                window.SetStatus("Ctrl+Shift+Space is already used by another app. Shortcut editing will be available in Settings.");
        }
        catch (Exception error)
        {
            hotkeyService?.Dispose();
            hotkeyService = null;
            window.SetStatus($"The global shortcut could not be registered: {error.Message}");
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
            window.SetStatus($"Windows session-lock monitoring is unavailable: {error.Message}");
        }
    }
}
