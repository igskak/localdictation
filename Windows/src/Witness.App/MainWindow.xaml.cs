using System.Windows;
using System.Diagnostics;
using System.Globalization;
using Witness.Core.Languages;
using Witness.Core.Models;

namespace Witness.App;

public partial class MainWindow : Window
{
    internal event EventHandler? ModelDownloadRequested;
    internal event EventHandler? ModelDownloadCancelRequested;
    internal event Action<LanguageProfile>? LanguageProfileChanged;

    public MainWindow()
    {
        InitializeComponent();
        LanguageProfileBox.ItemsSource = BuildLanguageProfiles();
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

    internal void ShowModelDisclosure(long sizeBytes)
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelStatusText.Text = $"Witness needs the multilingual speech model ({FormatMegabytes(sizeBytes)} MiB). It is downloaded from Hugging Face/CDN once, verified locally, and then reused offline. No audio, transcript, language choice, device ID, or license data is sent.";
        ModelProgress.Visibility = Visibility.Collapsed;
        ModelDownloadButton.Content = "Download speech model";
        ModelDownloadButton.IsEnabled = true;
        ModelCancelButton.Visibility = Visibility.Collapsed;
    }

    internal void ShowModelProgress(ModelPreparationProgress progress)
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelProgress.Visibility = Visibility.Visible;
        ModelDownloadButton.IsEnabled = false;
        ModelCancelButton.Visibility = Visibility.Visible;
        ModelProgress.IsIndeterminate = progress.Stage is not ModelPreparationStage.Downloading;
        ModelProgress.Value = progress.Fraction;
        ModelStatusText.Text = progress.Stage switch
        {
            ModelPreparationStage.Downloading => $"Downloading locally… {progress.Fraction:P0}",
            ModelPreparationStage.Verifying => "Verifying the model size and SHA-256…",
            _ => "Checking the local speech model…",
        };
    }

    internal void ShowModelReady()
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelStatusText.Text = "Speech model verified and ready for offline use.";
        ModelProgress.IsIndeterminate = false;
        ModelProgress.Value = 1;
        ModelProgress.Visibility = Visibility.Visible;
        ModelDownloadButton.Visibility = Visibility.Collapsed;
        ModelCancelButton.Visibility = Visibility.Collapsed;
    }

    internal void ShowModelCancelled()
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelStatusText.Text = "Model download cancelled. The partial file was removed.";
        ShowModelRetryButton();
    }

    internal void ShowModelError(string message)
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelStatusText.Text = message;
        ShowModelRetryButton();
    }

    internal void ShowModelSpaceError(long requiredBytes, long availableBytes) =>
        ShowModelError($"Not enough free space. Witness needs {FormatMegabytes(requiredBytes)} MiB including its safety reserve; {FormatMegabytes(availableBytes)} MiB is available. Free space and retry.");

    private void ShowModelRetryButton()
    {
        ModelProgress.IsIndeterminate = false;
        ModelProgress.Visibility = Visibility.Collapsed;
        ModelDownloadButton.Content = "Retry model download";
        ModelDownloadButton.Visibility = Visibility.Visible;
        ModelDownloadButton.IsEnabled = true;
        ModelCancelButton.Visibility = Visibility.Collapsed;
    }

    private static string FormatMegabytes(long bytes) =>
        Math.Ceiling(bytes / (1024D * 1024D)).ToString("N0", CultureInfo.CurrentCulture);

    private void DownloadModel(object sender, RoutedEventArgs e) =>
        ModelDownloadRequested?.Invoke(this, EventArgs.Empty);

    private void CancelModelDownload(object sender, RoutedEventArgs e) =>
        ModelDownloadCancelRequested?.Invoke(this, EventArgs.Empty);

    private void ChangeLanguageProfile(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (LanguageProfileBox.SelectedItem is LanguageProfileOption option)
        {
            LanguageProfileChanged?.Invoke(option.Profile);
            SetStatus($"Speech profile selected: {option.Label}. Hold Ctrl+Shift+Space to dictate locally.");
        }
    }

    private static IReadOnlyList<LanguageProfileOption> BuildLanguageProfiles()
    {
        var choices = new List<LanguageProfileOption>
        {
            new(
                "Automatic — Deutsch, English, русский, українська (verified)",
                new LanguageProfile(
                    SpeechLanguage.German,
                    SpeechLanguage.English,
                    SpeechLanguage.Russian,
                    SpeechLanguage.Ukrainian)),
        };
        choices.AddRange(LanguageCatalog.All.Select(entry => new LanguageProfileOption(
            $"{entry.NativeName} — {entry.EnglishName}",
            new LanguageProfile(new SpeechLanguage(entry.Code)))));
        return choices;
    }

    private void OpenMicrophonePrivacySettings(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });

    private sealed record LanguageProfileOption(string Label, LanguageProfile Profile)
    {
        public override string ToString() => Label;
    }
}
