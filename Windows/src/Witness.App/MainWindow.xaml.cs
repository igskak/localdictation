using System.Windows;
using System.Diagnostics;

namespace Witness.App;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
    }

    internal void SetStatus(string status)
    {
        StatusText.Text = status;
        PrivacySettingsButton.Visibility = Visibility.Collapsed;
    }

    internal void ShowMicrophoneAccessDenied()
    {
        StatusText.Text = "Microphone access is off. Witness does not show a fake permission prompt; Windows controls desktop microphone access.";
        PrivacySettingsButton.Visibility = Visibility.Visible;
    }

    private void OpenMicrophonePrivacySettings(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
}
