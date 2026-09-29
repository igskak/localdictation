using System.Windows;
using System.Diagnostics;
using System.Globalization;
using Witness.Core.History;
using Witness.Core.Languages;
using Witness.Core.Models;
using Witness.Core.Review;

namespace Witness.App;

public partial class MainWindow : Window
{
    internal event EventHandler? ModelDownloadRequested;
    internal event EventHandler? ModelDownloadCancelRequested;
    internal event EventHandler? ReviewDismissed;
    internal event Action<LanguageProfile>? LanguageProfileChanged;
    private ProcessedDictation? displayedResult;
    private bool displaysRawTranscript;

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

    internal void BeginDictation()
    {
        displayedResult = null;
        displaysRawTranscript = false;
        AttentionPanel.Visibility = Visibility.Collapsed;
        ReviewPanel.Visibility = Visibility.Collapsed;
        ReviewReasonsList.ItemsSource = null;
    }

    internal void ShowDictationResult(
        ProcessedDictation result,
        IReadOnlyList<RecentDictation> recentDictations)
    {
        displayedResult = result ?? throw new ArgumentNullException(nameof(result));
        displaysRawTranscript = false;
        UpdateHistory(recentDictations);
        ReviewPanel.Visibility = Visibility.Collapsed;
        if (result.Review.DeservesAttention)
        {
            AttentionText.Text = result.Review.Flagged.Count == 1
                ? "One fragment is worth checking. The text was already delivered."
                : $"{result.Review.Flagged.Count} fragments are worth checking. The text was already delivered.";
            AttentionPanel.Visibility = Visibility.Visible;
        }
        else
        {
            AttentionPanel.Visibility = Visibility.Collapsed;
        }
    }

    internal void ClearDictationResult(IReadOnlyList<RecentDictation> recentDictations)
    {
        BeginDictation();
        UpdateHistory(recentDictations);
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

    private void OpenLatestReview(object sender, RoutedEventArgs e)
    {
        if (displayedResult is null)
        {
            return;
        }
        AttentionPanel.Visibility = Visibility.Collapsed;
        ReviewPanel.Visibility = Visibility.Visible;
        ShowReviewContents();
    }

    private void DismissLatestAttention(object sender, RoutedEventArgs e)
    {
        AttentionPanel.Visibility = Visibility.Collapsed;
        ReviewDismissed?.Invoke(this, EventArgs.Empty);
    }

    private void CloseLatestReview(object sender, RoutedEventArgs e)
    {
        ReviewPanel.Visibility = Visibility.Collapsed;
        ReviewDismissed?.Invoke(this, EventArgs.Empty);
    }

    private void ToggleRawTranscript(object sender, RoutedEventArgs e)
    {
        if (displayedResult is null)
        {
            return;
        }
        displaysRawTranscript = !displaysRawTranscript;
        ShowReviewContents();
    }

    private void ShowReviewContents()
    {
        if (displayedResult is null)
        {
            return;
        }
        ReviewModeText.Text = displaysRawTranscript
            ? "Raw transcript, exactly as recognized"
            : "Conservatively cleaned text already delivered";
        ReviewTranscriptText.Text = displaysRawTranscript
            ? displayedResult.RawText
            : displayedResult.TextForInsertion;
        ToggleRawButton.Content = displaysRawTranscript
            ? "Show cleaned text"
            : "Show raw transcript";
        ReviewReasonsList.ItemsSource = displayedResult.Review.Highlighted
            .Select(ReviewDisplayItem.From)
            .ToArray();
    }

    private void UpdateHistory(IReadOnlyList<RecentDictation> recentDictations)
    {
        ArgumentNullException.ThrowIfNull(recentDictations);
        RecentDictationsList.ItemsSource = recentDictations;
        HistoryExpander.Visibility = recentDictations.Count == 0
            ? Visibility.Collapsed
            : Visibility.Visible;
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

    private sealed record ReviewDisplayItem(string DisplayText)
    {
        public static ReviewDisplayItem From(RiskSpan span)
        {
            var label = span.Reason switch
            {
                RiskReasonKind.Number => "Number",
                RiskReasonKind.Date => "Date",
                RiskReasonKind.Amount => "Amount",
                RiskReasonKind.NamedEntity => "Name or entity",
                RiskReasonKind.Glossary => "Dictionary near-match",
                RiskReasonKind.MalformedWord => "Unusual word shape",
                RiskReasonKind.LanguageSwitch => "Language switch",
                RiskReasonKind.CleanupEdit => "Cleanup change",
                _ => "Recognition detail",
            };
            var attention = span.Weight >= ReviewPolicy.Default.AttentionThreshold
                ? "check"
                : "note";
            return new ReviewDisplayItem($"{label} ({attention}): {span.Text}");
        }
    }
}
