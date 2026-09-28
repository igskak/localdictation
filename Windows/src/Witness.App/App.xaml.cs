namespace Witness.App;

public partial class App : System.Windows.Application
{
    private TrayIconService? trayIcon;
    private ActivityWindow? activityWindow;
    private Witness.Platform.Windows.Hotkeys.GlobalHotkeyService? hotkeyService;
    private DictationCaptureController? captureController;
    private Witness.Platform.Windows.Lifecycle.DesktopSessionMonitor? sessionMonitor;
    private ModelSetupController? modelSetupController;
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
        MainWindow.SourceInitialized += (_, _) => ConfigureSessionMonitor((MainWindow)MainWindow);

        activityWindow = new ActivityWindow();
        modelSetupController = new ModelSetupController(Dispatcher, (MainWindow)MainWindow);
        captureController = new DictationCaptureController(Dispatcher, activityWindow, (MainWindow)MainWindow);
        trayIcon = new TrayIconService();
        trayIcon.OpenRequested += (_, _) => ShowMainWindow();
        trayIcon.ExitRequested += (_, _) => ExitApplication();
        ConfigureHotkey((MainWindow)MainWindow);
        MainWindow.Show();
        _ = modelSetupController.InspectAsync();
    }

    protected override void OnExit(System.Windows.ExitEventArgs e)
    {
        trayIcon?.Dispose();
        hotkeyService?.Dispose();
        sessionMonitor?.Dispose();
        captureController?.Dispose();
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
            var chord = new Witness.Core.Input.HotkeyChord(
                Witness.Core.Input.HotkeyModifiers.Control | Witness.Core.Input.HotkeyModifiers.Shift,
                0x20);
            var result = hotkeyService.Change(chord);
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
