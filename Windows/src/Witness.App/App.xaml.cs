namespace Witness.App;

public partial class App : System.Windows.Application
{
    private TrayIconService? trayIcon;
    private ActivityWindow? activityWindow;
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
        trayIcon = new TrayIconService();
        trayIcon.OpenRequested += (_, _) => ShowMainWindow();
        trayIcon.ExitRequested += (_, _) => ExitApplication();
        MainWindow.Show();
    }

    protected override void OnExit(System.Windows.ExitEventArgs e)
    {
        trayIcon?.Dispose();
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
}
