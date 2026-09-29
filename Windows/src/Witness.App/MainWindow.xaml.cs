using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Witness.Core.Audio;
using Witness.Core.History;
using Witness.Core.Input;
using Witness.Core.Languages;
using Witness.Core.Models;
using Witness.Core.Review;
using Witness.Core.Settings;
using WpfButton = System.Windows.Controls.Button;
using WpfCheckBox = System.Windows.Controls.CheckBox;
using WpfRadioButton = System.Windows.Controls.RadioButton;
using WpfTextBox = System.Windows.Controls.TextBox;

namespace Witness.App;

public partial class MainWindow : Window
{
    internal event EventHandler? ModelDownloadRequested;
    internal event EventHandler? ModelDownloadCancelRequested;
    internal event EventHandler? ReviewDismissed;
    internal event Action<string>? ProtectedCopyRequested;
    internal event Action<RiskSpan>? ReviewReplayRequested;
    internal event Action<LanguageProfile>? LanguageProfileChanged;
    internal event Action<HotkeyActivationMode>? ActivationModeChanged;
    internal event Action<bool>? LaunchAtStartupChanged;
    internal event Action<AudioInputSelection>? AudioInputChanged;
    internal event Action<bool>? ProductEventSharingChanged;
    internal event Action<VoiceActivityConfiguration>? VoiceActivityConfigurationChanged;
    internal event Action<string, SpeechLanguage>? GlossaryTermAddRequested;
    internal event Action<GlossaryEntry>? GlossaryTermRemoveRequested;
    internal event Action<LanguageProfile>? OnboardingLanguageSelectionConfirmed;
    internal event EventHandler? OnboardingCompleted;

    private readonly List<string> selectedLanguages = [];
    private readonly List<string> onboardingLanguages = [];
    private readonly List<LanguageSelectionItem> languageItems = [];
    private readonly List<LanguageSelectionItem> onboardingLanguageItems = [];
    private IReadOnlyList<AudioInputDevice> audioInputs = [];
    private AudioInputSelection audioInputSelection = AudioInputSelection.SystemDefault;
    private VoiceActivityConfiguration voiceConfiguration = VoiceActivityConfiguration.Default;
    private ProcessedDictation? displayedResult;
    private bool displaysRawTranscript;
    private bool updatingControls;

    public MainWindow()
    {
        InitializeComponent();
        BuildLanguageItems();
        ActivationModeBox.ItemsSource = new[]
        {
            new ActivationModeOption(ResourceText("HoldMode"), HotkeyActivationMode.Hold),
            new ActivationModeOption(ResourceText("ToggleMode"), HotkeyActivationMode.Toggle),
        };
        SetVoiceConfiguration(VoiceActivityConfiguration.Default);
        ShowSection("General");
    }

    internal void ApplyPreferences(UserPreferences preferences, bool launchAtStartup)
    {
        var normalized = preferences.Normalized();
        updatingControls = true;
        try
        {
            selectedLanguages.Clear();
            selectedLanguages.AddRange(normalized.LanguageCodes);
            onboardingLanguages.Clear();
            onboardingLanguages.AddRange(normalized.LanguageCodes);
            RefreshLanguageLists();
            ActivationModeBox.SelectedItem = ActivationModeBox.Items
                .OfType<ActivationModeOption>()
                .First(option => option.Mode == normalized.ActivationMode);
            LaunchAtStartupCheckBox.IsChecked = launchAtStartup;
            audioInputSelection = normalized.AudioInput;
            ProductEventSharingCheckBox.IsChecked = normalized.ProductEventSharingEnabled;
            OnboardingProductEventSharingCheckBox.IsChecked = normalized.ProductEventSharingEnabled;
            ShowOnboarding(!normalized.OnboardingCompleted);
        }
        finally
        {
            updatingControls = false;
        }
    }

    internal void SetLaunchAtStartup(bool enabled)
    {
        updatingControls = true;
        try
        {
            LaunchAtStartupCheckBox.IsChecked = enabled;
        }
        finally
        {
            updatingControls = false;
        }
    }

    internal void ShowOnboarding(bool visible)
    {
        OnboardingLanguagesStep.Visibility = Visibility.Visible;
        OnboardingReadyStep.Visibility = Visibility.Collapsed;
        OnboardingPanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        SettingsShell.IsEnabled = !visible;
        if (visible)
        {
            RefreshOnboardingLanguages();
            OnboardingLanguagesList.Focus();
        }
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

    internal void ShowDictationResult(ProcessedDictation result, IReadOnlyList<RecentDictation> recentDictations)
    {
        displayedResult = result ?? throw new ArgumentNullException(nameof(result));
        displaysRawTranscript = false;
        UpdateHistory(recentDictations);
        ReviewPanel.Visibility = Visibility.Collapsed;
        if (result.Review.DeservesAttention)
        {
            AttentionText.Text = result.Review.Flagged.Count == 1
                ? ResourceText("AttentionOne")
                : string.Format(CultureInfo.CurrentCulture, ResourceText("AttentionMany"), result.Review.Flagged.Count);
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
        StatusText.Text = ResourceText("MicrophoneAccessOff");
        PrivacySettingsButton.Visibility = Visibility.Visible;
    }

    internal void ShowAudioInputs(
        IReadOnlyList<AudioInputDevice> devices,
        AudioInputSelection selection,
        string? error = null)
    {
        audioInputs = devices ?? throw new ArgumentNullException(nameof(devices));
        audioInputSelection = selection ?? throw new ArgumentNullException(nameof(selection));
        var options = new List<AudioInputOption>
        {
            new(ResourceText("SystemDefaultInput"), AudioInputSelection.SystemDefault),
            new(ResourceText("BuiltInInput"), AudioInputSelection.BuiltIn),
        };
        options.AddRange(devices.Select(device => new AudioInputOption(
            device.IsSystemDefault ? ResourceFormat("WindowsDefaultDevice", device.DisplayName) : device.DisplayName,
            AudioInputSelection.Specific(device.Id))));
        if (selection.Kind == AudioInputSelectionKind.Specific
            && !devices.Any(device => string.Equals(device.Id, selection.DeviceId, StringComparison.Ordinal)))
        {
            options.Add(new AudioInputOption(ResourceText("PreviousInputUnavailable"), selection));
        }

        updatingControls = true;
        try
        {
            AudioInputBox.ItemsSource = options;
            AudioInputBox.SelectedItem = options.First(option => SameInput(option.Selection, selection));
        }
        finally
        {
            updatingControls = false;
        }
        AudioInputStatusText.Text = error ?? (devices.Count == 0
            ? ResourceText("NoActiveInput")
            : ResourceText("AudioInputNextRecording"));
    }

    internal void ShowGlossary(IReadOnlyList<GlossaryEntry> entries, string? status = null)
    {
        var rows = entries.Select(entry => new GlossaryDisplayItem(
            $"{entry.Term} — {LanguageLabel(entry.Language)}",
            entry)).ToArray();
        GlossaryList.ItemsSource = rows;
        GlossaryStatusText.Text = status ?? (rows.Length == 0
            ? ResourceText("NoTerms")
            : rows.Length == 1
                ? ResourceText("SessionTermCountOne")
                : ResourceFormat("SessionTermCountMany", rows.Length));
    }

    internal void ClearGlossaryTermInput() => GlossaryTermBox.Clear();

    internal void ShowDiagnostics(
        LanguageProfile profile,
        int glossaryCount,
        int historyCount,
        bool retainsReviewAudio,
        IReadOnlyList<string> lexiconCapabilities)
    {
        var resolved = AudioInputSelectionPolicy.Resolve(audioInputSelection, audioInputs);
        DiagnosticsInputText.Text = string.Join(Environment.NewLine,
        [
            ResourceFormat("DiagnosticsSelected", AudioInputLabel(audioInputSelection)),
            ResourceFormat("DiagnosticsResolved", resolved.Device?.DisplayName ?? ResourceText("NoActiveInput")),
            ResourceText(resolved.UsedFallback ? "DiagnosticsFallbackYes" : "DiagnosticsFallbackNo"),
            ResourceText("DiagnosticsNormalized"),
        ]);
        DiagnosticsReviewText.Text = string.Join(Environment.NewLine,
        [
            ResourceFormat("DiagnosticsLanguageProfile", profile.Id),
            ResourceFormat("DiagnosticsGlossaryCount", glossaryCount),
            ResourceFormat("DiagnosticsHistoryCount", historyCount, RecentDictationHistory.MaximumCount),
            ResourceText(retainsReviewAudio ? "DiagnosticsAudioRetained" : "DiagnosticsAudioClear"),
            ResourceFormat("DiagnosticsDictionaries", string.Join(", ", lexiconCapabilities)),
            ResourceText("DiagnosticsPrivacy"),
        ]);
    }

    internal void ShowModelDisclosure(long sizeBytes)
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelStatusText.Text = ResourceFormat("ModelDisclosure", FormatMegabytes(sizeBytes));
        ModelProgress.Visibility = Visibility.Collapsed;
        ModelDownloadButton.Content = ResourceText("DownloadModel");
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
            ModelPreparationStage.Downloading => ResourceFormat("ModelDownloading", progress.Fraction),
            ModelPreparationStage.Verifying => ResourceText("ModelVerifying"),
            _ => ResourceText("ModelChecking"),
        };
    }

    internal void ShowModelReady()
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelStatusText.Text = ResourceText("ModelReady");
        ModelProgress.IsIndeterminate = false;
        ModelProgress.Value = 1;
        ModelProgress.Visibility = Visibility.Visible;
        ModelDownloadButton.Visibility = Visibility.Collapsed;
        ModelCancelButton.Visibility = Visibility.Collapsed;
    }

    internal void ShowModelCancelled()
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelStatusText.Text = ResourceText("ModelCancelled");
        ShowModelRetryButton();
    }

    internal void ShowModelError(string message)
    {
        ModelSetupPanel.Visibility = Visibility.Visible;
        ModelStatusText.Text = message;
        ShowModelRetryButton();
    }

    internal void ShowModelSpaceError(long requiredBytes, long availableBytes) =>
        ShowModelError(ResourceFormat("ModelSpaceError", FormatMegabytes(requiredBytes), FormatMegabytes(availableBytes)));

    private void ShowModelRetryButton()
    {
        ModelProgress.IsIndeterminate = false;
        ModelProgress.Visibility = Visibility.Collapsed;
        ModelDownloadButton.Content = ResourceText("RetryModel");
        ModelDownloadButton.Visibility = Visibility.Visible;
        ModelDownloadButton.IsEnabled = true;
        ModelCancelButton.Visibility = Visibility.Collapsed;
    }

    private static string FormatMegabytes(long bytes) =>
        Math.Ceiling(bytes / (1024D * 1024D)).ToString("N0", CultureInfo.CurrentCulture);

    private void NavigateSettings(object sender, RoutedEventArgs e)
    {
        if (!IsInitialized || sender is not WpfRadioButton { Tag: string section }) return;
        ShowSection(section);
    }

    private void ShowSection(string section)
    {
        var panels = new Dictionary<string, FrameworkElement>(StringComparer.Ordinal)
        {
            ["General"] = GeneralPanel,
            ["Languages"] = LanguagesPanel,
            ["Boundary"] = BoundaryPanel,
            ["Dictionary"] = DictionaryPanel,
            ["License"] = LicensePanel,
            ["Diagnostics"] = DiagnosticsPanel,
        };
        foreach (var panel in panels.Values) panel.Visibility = Visibility.Collapsed;
        panels[section].Visibility = Visibility.Visible;
        PageTitle.Text = ResourceText($"{section}Title");
        PageDescription.Text = ResourceText($"{section}Description");
    }

    private void BuildLanguageItems()
    {
        languageItems.Clear();
        onboardingLanguageItems.Clear();
        foreach (var entry in LanguageCatalog.All)
        {
            languageItems.Add(new LanguageSelectionItem(entry.Code, LanguageLabel(entry), false));
            onboardingLanguageItems.Add(new LanguageSelectionItem(entry.Code, LanguageLabel(entry), false));
        }
    }

    private void FilterLanguages(object sender, TextChangedEventArgs e) => RefreshLanguageLists();

    private void ToggleLanguage(object sender, RoutedEventArgs e)
    {
        if (updatingControls || sender is not WpfCheckBox { Tag: string code }) return;
        if (!selectedLanguages.Remove(code)) selectedLanguages.Add(code);
        if (selectedLanguages.Count == 0) selectedLanguages.Add(code);
        RefreshLanguageLists();
        var profile = CurrentProfile();
        UpdateGlossaryLanguageChoices(profile);
        LanguageProfileChanged?.Invoke(profile);
    }

    private void ToggleOnboardingLanguage(object sender, RoutedEventArgs e)
    {
        if (updatingControls || sender is not WpfCheckBox { Tag: string code }) return;
        if (!onboardingLanguages.Remove(code)) onboardingLanguages.Add(code);
        if (onboardingLanguages.Count == 0) onboardingLanguages.Add(code);
        RefreshOnboardingLanguages();
    }

    private void RefreshLanguageLists()
    {
        var filter = LanguageFilterBox?.Text?.Trim() ?? string.Empty;
        var filtered = languageItems
            .Select(item => item with { IsSelected = selectedLanguages.Contains(item.Code) })
            .Where(item => filter.Length == 0 || item.Label.Contains(filter, StringComparison.CurrentCultureIgnoreCase))
            .ToArray();
        if (LanguagesList is not null) LanguagesList.ItemsSource = filtered;
        if (SelectedLanguageCountText is not null)
            SelectedLanguageCountText.Text = ResourceFormat("SelectedCount", selectedLanguages.Count);
        if (GlossaryLanguageBox is not null) UpdateGlossaryLanguageChoices(CurrentProfile());
    }

    private void RefreshOnboardingLanguages()
    {
        OnboardingLanguagesList.ItemsSource = onboardingLanguageItems
            .Select(item => item with { IsSelected = onboardingLanguages.Contains(item.Code) })
            .ToArray();
        OnboardingLanguageCountText.Text = ResourceFormat("SelectedCount", onboardingLanguages.Count);
    }

    private LanguageProfile CurrentProfile() => new(
        selectedLanguages.Select(code => new SpeechLanguage(code)));

    private void UpdateGlossaryLanguageChoices(LanguageProfile profile)
    {
        var selectedCode = (GlossaryLanguageBox.SelectedItem as LanguageOption)?.Language.Code;
        var options = profile.Languages.Select(language => new LanguageOption(LanguageLabel(language), language)).ToArray();
        GlossaryLanguageBox.ItemsSource = options;
        GlossaryLanguageBox.SelectedItem = options.FirstOrDefault(option => option.Language.Code == selectedCode) ?? options.FirstOrDefault();
    }

    private void ChangeActivationMode(object sender, SelectionChangedEventArgs e)
    {
        if (!updatingControls && ActivationModeBox.SelectedItem is ActivationModeOption option)
            ActivationModeChanged?.Invoke(option.Mode);
    }

    private void ToggleLaunchAtStartup(object sender, RoutedEventArgs e)
    {
        if (!updatingControls) LaunchAtStartupChanged?.Invoke(LaunchAtStartupCheckBox.IsChecked == true);
    }

    private void RefreshAudioInputs(object sender, RoutedEventArgs e) => AudioInputChanged?.Invoke(audioInputSelection);

    private void ChangeAudioInput(object sender, SelectionChangedEventArgs e)
    {
        if (updatingControls || AudioInputBox.SelectedItem is not AudioInputOption option) return;
        audioInputSelection = option.Selection;
        AudioInputChanged?.Invoke(option.Selection);
    }

    private void ChangeProductEventSharing(object sender, RoutedEventArgs e)
    {
        if (updatingControls || sender is not WpfCheckBox source) return;
        var enabled = source.IsChecked == true;
        updatingControls = true;
        try
        {
            ProductEventSharingCheckBox.IsChecked = enabled;
            OnboardingProductEventSharingCheckBox.IsChecked = enabled;
        }
        finally
        {
            updatingControls = false;
        }
        ProductEventSharingChanged?.Invoke(enabled);
    }

    private void SetVoiceConfiguration(VoiceActivityConfiguration configuration)
    {
        updatingControls = true;
        try
        {
            voiceConfiguration = configuration.Validated();
            SpeechThresholdSlider.Value = voiceConfiguration.SpeechThreshold;
            SilenceThresholdSlider.Value = voiceConfiguration.SilenceThreshold;
            TrailingSilenceSlider.Value = voiceConfiguration.TrailingSilenceDuration;
            MaximumUtteranceSlider.Value = voiceConfiguration.MaximumUtteranceDuration;
            UpdateBoundaryLabels();
        }
        finally
        {
            updatingControls = false;
        }
    }

    private void ChangeBoundary(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!IsInitialized || updatingControls) return;
        voiceConfiguration = voiceConfiguration with
        {
            SpeechThreshold = (float)SpeechThresholdSlider.Value,
            SilenceThreshold = (float)SilenceThresholdSlider.Value,
            TrailingSilenceDuration = TrailingSilenceSlider.Value,
            MaximumUtteranceDuration = MaximumUtteranceSlider.Value,
        };
        voiceConfiguration = voiceConfiguration.Validated();
        updatingControls = true;
        try
        {
            SpeechThresholdSlider.Value = voiceConfiguration.SpeechThreshold;
            SilenceThresholdSlider.Value = voiceConfiguration.SilenceThreshold;
            TrailingSilenceSlider.Value = voiceConfiguration.TrailingSilenceDuration;
            MaximumUtteranceSlider.Value = voiceConfiguration.MaximumUtteranceDuration;
        }
        finally
        {
            updatingControls = false;
        }
        UpdateBoundaryLabels();
        VoiceActivityConfigurationChanged?.Invoke(voiceConfiguration);
    }

    private void UpdateBoundaryLabels()
    {
        SpeechThresholdValue.Text = $"{ResourceText("SpeechThreshold")}: {voiceConfiguration.SpeechThreshold:0.000}";
        SilenceThresholdValue.Text = $"{ResourceText("SilenceThreshold")}: {voiceConfiguration.SilenceThreshold:0.000}";
        TrailingSilenceValue.Text = $"{ResourceText("TrailingSilence")}: {voiceConfiguration.TrailingSilenceDuration:0.0} s";
        MaximumUtteranceValue.Text = $"{ResourceText("MaximumUtterance")}: {voiceConfiguration.MaximumUtteranceDuration:0} s";
    }

    private void AddGlossaryTerm(object sender, RoutedEventArgs e)
    {
        if (GlossaryLanguageBox.SelectedItem is LanguageOption option)
            GlossaryTermAddRequested?.Invoke(GlossaryTermBox.Text, option.Language);
    }

    private void RemoveGlossaryTerm(object sender, RoutedEventArgs e)
    {
        if (sender is WpfButton { Tag: GlossaryEntry entry }) GlossaryTermRemoveRequested?.Invoke(entry);
    }

    private void OnboardingContinue(object sender, RoutedEventArgs e)
    {
        if (onboardingLanguages.Count == 0) return;
        selectedLanguages.Clear();
        selectedLanguages.AddRange(onboardingLanguages);
        RefreshLanguageLists();
        var profile = CurrentProfile();
        OnboardingLanguageSelectionConfirmed?.Invoke(profile);
        OnboardingLanguagesStep.Visibility = Visibility.Collapsed;
        OnboardingReadyStep.Visibility = Visibility.Visible;
    }

    private void OnboardingFinish(object sender, RoutedEventArgs e)
    {
        OnboardingPanel.Visibility = Visibility.Collapsed;
        SettingsShell.IsEnabled = true;
        OnboardingCompleted?.Invoke(this, EventArgs.Empty);
    }

    private void OnboardingBack(object sender, RoutedEventArgs e)
    {
        OnboardingReadyStep.Visibility = Visibility.Collapsed;
        OnboardingLanguagesStep.Visibility = Visibility.Visible;
        OnboardingLanguagesList.Focus();
    }

    private void DownloadModel(object sender, RoutedEventArgs e) => ModelDownloadRequested?.Invoke(this, EventArgs.Empty);
    private void CancelModelDownload(object sender, RoutedEventArgs e) => ModelDownloadCancelRequested?.Invoke(this, EventArgs.Empty);

    private void OpenLatestReview(object sender, RoutedEventArgs e)
    {
        if (displayedResult is null) return;
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
        if (displayedResult is null) return;
        displaysRawTranscript = !displaysRawTranscript;
        ShowReviewContents();
    }

    private void CopyDisplayedReviewText(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(ReviewTranscriptText.Text)) ProtectedCopyRequested?.Invoke(ReviewTranscriptText.Text);
    }

    private void ReplayReviewFragment(object sender, RoutedEventArgs e)
    {
        if (sender is WpfButton { Tag: RiskSpan span }) ReviewReplayRequested?.Invoke(span);
    }

    private void CanCopyProtectedText(object sender, CanExecuteRoutedEventArgs e)
    {
        e.CanExecute = Keyboard.FocusedElement is WpfTextBox textBox && !string.IsNullOrEmpty(textBox.SelectedText);
        e.Handled = true;
    }

    private void CopyProtectedText(object sender, ExecutedRoutedEventArgs e)
    {
        if (Keyboard.FocusedElement is WpfTextBox textBox && !string.IsNullOrEmpty(textBox.SelectedText))
            ProtectedCopyRequested?.Invoke(textBox.SelectedText);
        e.Handled = true;
    }

    private void ShowReviewContents()
    {
        if (displayedResult is null) return;
        ReviewModeText.Text = displaysRawTranscript
            ? ResourceText("ReviewRawMode")
            : ResourceText("ReviewCleanedMode");
        ReviewTranscriptText.Text = displaysRawTranscript ? displayedResult.RawText : displayedResult.TextForInsertion;
        ToggleRawButton.Content = displaysRawTranscript
            ? ResourceText("ShowCleanedText")
            : ResourceText("ShowRawTranscript");
        ReviewReasonsList.ItemsSource = displayedResult.Review.Highlighted.Select(ReviewDisplayItemFrom).ToArray();
    }

    private void UpdateHistory(IReadOnlyList<RecentDictation> recentDictations)
    {
        ArgumentNullException.ThrowIfNull(recentDictations);
        RecentDictationsList.ItemsSource = recentDictations;
        HistoryExpander.Visibility = recentDictations.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OpenMicrophonePrivacySettings(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });

    internal string ResourceText(string key) => TryFindResource(key) as string ?? key;

    internal string ResourceFormat(string key, params object[] arguments) =>
        string.Format(CultureInfo.CurrentCulture, ResourceText(key), arguments);

    private static string LanguageLabel(LanguageEntry entry) =>
        entry.NativeName == entry.EnglishName ? entry.NativeName : $"{entry.NativeName} — {entry.EnglishName}";

    private static string LanguageLabel(SpeechLanguage language) =>
        LanguageCatalog.ByCode.TryGetValue(language.Code, out var entry) ? LanguageLabel(entry) : language.Code;

    private string AudioInputLabel(AudioInputSelection selection) => selection.Kind switch
    {
        AudioInputSelectionKind.SystemDefault => ResourceText("SystemDefaultInput"),
        AudioInputSelectionKind.Specific => audioInputs.FirstOrDefault(device => device.Id == selection.DeviceId)?.DisplayName
            ?? ResourceText("PreviousInputUnavailable"),
        _ => ResourceText("BuiltInInput"),
    };

    private static bool SameInput(AudioInputSelection left, AudioInputSelection right) =>
        left.Kind == right.Kind && string.Equals(left.DeviceId, right.DeviceId, StringComparison.Ordinal);

    private sealed record LanguageSelectionItem(string Code, string Label, bool IsSelected);
    private sealed record LanguageOption(string Label, SpeechLanguage Language)
    {
        public override string ToString() => Label;
    }
    private sealed record ActivationModeOption(string Label, HotkeyActivationMode Mode)
    {
        public override string ToString() => Label;
    }
    private sealed record AudioInputOption(string Label, AudioInputSelection Selection)
    {
        public override string ToString() => Label;
    }
    private sealed record GlossaryDisplayItem(string Label, GlossaryEntry Entry);

    private ReviewDisplayItem ReviewDisplayItemFrom(RiskSpan span)
    {
        var label = span.Reason switch
        {
            RiskReasonKind.Number => ResourceText("RiskNumber"),
            RiskReasonKind.Date => ResourceText("RiskDate"),
            RiskReasonKind.Amount => ResourceText("RiskAmount"),
            RiskReasonKind.NamedEntity => ResourceText("RiskEntity"),
            RiskReasonKind.Glossary => ResourceText("RiskGlossary"),
            RiskReasonKind.MalformedWord => ResourceText("RiskMalformed"),
            RiskReasonKind.LanguageSwitch => ResourceText("RiskLanguageSwitch"),
            RiskReasonKind.CleanupEdit => ResourceText("RiskCleanup"),
            _ => ResourceText("RiskDetail"),
        };
        var attention = ResourceText(span.Weight >= ReviewPolicy.Default.AttentionThreshold ? "RiskCheck" : "RiskNote");
        return new ReviewDisplayItem(
            ResourceFormat("RiskDisplay", label, attention, span.Text),
            span.IsPlayable && span.Weight >= ReviewPolicy.Default.AttentionThreshold,
            span);
    }

    private sealed record ReviewDisplayItem(string DisplayText, bool CanReplay, RiskSpan Span);
}
