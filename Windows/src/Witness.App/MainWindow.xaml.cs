using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Witness.Core.Audio;
using Witness.Core.History;
using Witness.Core.Input;
using Witness.Core.Languages;
using Witness.Core.Licensing;
using Witness.Core.Models;
using Witness.Core.Recording;
using Witness.Core.Review;
using Witness.Core.Settings;
using Witness.Update;
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
    internal event Action<string>? LicenseActivationRequested;
    internal event Action<string>? LicenseKeySubmitted;
    internal event EventHandler? LicenseRemovalRequested;
    internal event Action<LegalDocumentKind>? LegalDocumentRequested;
    internal event EventHandler? UpdateCheckRequested;
    internal event EventHandler? UpdateDownloadRequested;
    internal event EventHandler? UpdateInstallRequested;

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
    private bool licenseActivationAvailable;
    private bool licenseKeyAvailable;

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

    internal void ShowUpdateState(
        AppUpdateSnapshot snapshot,
        bool configured,
        string currentVersion,
        int currentBuild,
        string? configurationError = null)
    {
        UpdateCurrentVersionText.Text = ResourceFormat("UpdateCurrentVersion", currentVersion, currentBuild);
        UpdateReleaseNotesText.Text = snapshot.ReleaseNotes;
        UpdateReleaseNotesText.Visibility = string.IsNullOrWhiteSpace(snapshot.ReleaseNotes)
            ? Visibility.Collapsed
            : Visibility.Visible;
        UpdateProgress.Value = snapshot.ProgressPercent;
        UpdateProgress.Visibility = snapshot.State == AppUpdateState.Downloading
            ? Visibility.Visible
            : Visibility.Collapsed;

        var detail = snapshot.Message;
        UpdateStatusText.Text = !configured
            ? ResourceText(configurationError is null ? "UpdateNotConfigured" : "UpdateConfigurationInvalid")
            : detail ?? snapshot.State switch
            {
                AppUpdateState.Idle => ResourceText("UpdateManualOnly"),
                AppUpdateState.Checking => ResourceText("UpdateChecking"),
                AppUpdateState.UpToDate => ResourceText("UpdateUpToDate"),
                AppUpdateState.Available => ResourceFormat("UpdateAvailable", snapshot.Version ?? string.Empty, snapshot.Build ?? 0),
                AppUpdateState.Downloading => ResourceFormat("UpdateDownloading", snapshot.ProgressPercent),
                AppUpdateState.ReadyToInstall => ResourceText("UpdateReady"),
                AppUpdateState.Installing => ResourceText("UpdateInstalling"),
                _ => ResourceText("UpdateFailed"),
            };

        var busy = snapshot.State is AppUpdateState.Checking or AppUpdateState.Downloading or AppUpdateState.Installing;
        CheckForUpdatesButton.IsEnabled = configured && !busy;
        DownloadUpdateButton.Visibility = snapshot.State == AppUpdateState.Available ? Visibility.Visible : Visibility.Collapsed;
        DownloadUpdateButton.IsEnabled = configured && !busy;
        InstallUpdateButton.Visibility = snapshot.State == AppUpdateState.ReadyToInstall ? Visibility.Visible : Visibility.Collapsed;
        InstallUpdateButton.IsEnabled = configured && !busy;
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

    internal void ShowLicense(LicenseScreenState screen)
    {
        ArgumentNullException.ThrowIfNull(screen);
        var state = screen.State;
        switch (state.Kind)
        {
            case EntitlementStateKind.Ungated when state.Grace?.ExpiresAt is null:
                LicenseStandingHeading.Text = ResourceText("LicenseReadyHeading");
                LicenseStandingDetail.Text = ResourceText("LicenseReadyDetail");
                break;
            case EntitlementStateKind.Ungated:
                LicenseStandingHeading.Text = ResourceText("LicenseGraceHeading");
                LicenseStandingDetail.Text = ResourceFormat(
                    "LicenseGraceDetail",
                    FormatMoment(state.Grace!.ExpiresAt!.Value));
                break;
            case EntitlementStateKind.Licensed:
                ShowLicensedStanding(state.License!);
                break;
            case EntitlementStateKind.Locked:
                ShowLockedStanding(state.Lock!);
                break;
        }

        var activatesTrial = state.Kind == EntitlementStateKind.Ungated
            || state.Lock?.Kind == EntitlementLockKind.ActivationRequired;
        LicenseActivationHeading.Text = ResourceText(activatesTrial ? "ActivateTrial" : "RetrieveLicense");
        LicenseActivationButton.Content = ResourceText(activatesTrial ? "SendBetaKey" : "SendOwnedKey");
        licenseActivationAvailable = screen.ActivationConfigured
            && screen.AuthorityConfigured
            && screen.DeviceId is not null;
        LicenseActivationButton.IsEnabled = licenseActivationAvailable;
        LicenseEmailBox.IsEnabled = licenseActivationAvailable;
        LicenseActivationDetail.Text = screen.DeviceId is null
            ? screen.DeviceError ?? ResourceText("DeviceIdentityUnavailable")
            : !screen.AuthorityConfigured
                ? ResourceText("AuthorityNotConfiguredDetail")
                : screen.ActivationConfigured
                ? ResourceText("ActivationPrivacyDetail")
                : ResourceText("ActivationNotConfiguredDetail");

        licenseKeyAvailable = screen.AuthorityConfigured && screen.DeviceId is not null;
        LicenseKeyBox.IsEnabled = licenseKeyAvailable;
        UseLicenseKeyButton.IsEnabled = licenseKeyAvailable;
        RemoveLicenseButton.Visibility = screen.HasStoredLicenseToken ? Visibility.Visible : Visibility.Collapsed;
        ManualKeyDetail.Text = !screen.AuthorityConfigured
            ? ResourceText("AuthorityNotConfiguredDetail")
            : screen.DeviceId is null
                ? screen.DeviceError ?? ResourceText("DeviceIdentityUnavailable")
                : ResourceText("ManualKeyDetail");

        LicenseDeviceIdText.Text = screen.DeviceId ?? ResourceText("Unavailable");
        LicenseDeviceDetail.Text = screen.DeviceId is null
            ? screen.DeviceError ?? ResourceText("DeviceIdentityUnavailable")
            : ResourceText("DeviceIdentifierDetail");
    }

    internal void SetLicenseBusy(bool busy)
    {
        LicenseBusyProgress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        LicenseActivationButton.IsEnabled = !busy && licenseActivationAvailable;
        LicenseEmailBox.IsEnabled = !busy && licenseActivationAvailable;
        UseLicenseKeyButton.IsEnabled = !busy && licenseKeyAvailable;
        LicenseKeyBox.IsEnabled = !busy && licenseKeyAvailable;
        RemoveLicenseButton.IsEnabled = !busy;
    }

    internal void ShowLicenseNotice(string message)
    {
        LicenseNoticeText.Text = message;
        LicenseNoticeText.Visibility = Visibility.Visible;
    }

    internal void ClearLicenseNotice()
    {
        LicenseNoticeText.Text = string.Empty;
        LicenseNoticeText.Visibility = Visibility.Collapsed;
    }

    internal void ClearLicenseInputs()
    {
        LicenseEmailBox.Clear();
        LicenseKeyBox.Clear();
    }

    internal void OpenLicenseSection()
    {
        LicenseNavigation.IsChecked = true;
        ShowSection("License");
        LicensePanel.Focus();
    }

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

    private static string FormatMoment(DateTimeOffset value) =>
        value.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);

    private void ShowLicensedStanding(License license)
    {
        LicenseStandingHeading.Text = ResourceText(license.Kind switch
        {
            LicenseKind.Trial => "LicenseTrialHeading",
            LicenseKind.Annual => "LicenseAnnualHeading",
            _ => "LicenseLifetimeHeading",
        });
        LicenseStandingDetail.Text = license.ExpiresAt is DateTimeOffset expiry
            ? ResourceFormat("LicenseDatedDetail", license.Email, FormatMoment(expiry))
            : ResourceFormat("LicenseLifetimeDetail", license.Email, LifetimeUpdatePolicy.CoveredMajor(license.IssuedAt));
    }

    private void ShowLockedStanding(EntitlementLock entitlementLock)
    {
        switch (entitlementLock.Kind)
        {
            case EntitlementLockKind.ActivationRequired:
                LicenseStandingHeading.Text = ResourceText("LicenseActivationRequiredHeading");
                LicenseStandingDetail.Text = ResourceText("LicenseActivationRequiredDetail");
                break;
            case EntitlementLockKind.ExpiredTrial:
                LicenseStandingHeading.Text = ResourceText("LicenseTrialExpiredHeading");
                LicenseStandingDetail.Text = ResourceFormat("LicenseExpiredDetail", FormatMoment(entitlementLock.ExpiredAt!.Value));
                break;
            case EntitlementLockKind.ExpiredAnnual:
                LicenseStandingHeading.Text = ResourceText("LicenseAnnualExpiredHeading");
                LicenseStandingDetail.Text = ResourceFormat("LicenseExpiredDetail", FormatMoment(entitlementLock.ExpiredAt!.Value));
                break;
            default:
                LicenseStandingHeading.Text = ResourceText("LicenseUpdateRequiredHeading");
                LicenseStandingDetail.Text = ResourceFormat(
                    "LicenseUpdateRequiredDetail",
                    entitlementLock.CoveredMajor ?? 1,
                    entitlementLock.RunningMajor ?? 1);
                break;
        }
    }

    private void NavigateSettings(object sender, RoutedEventArgs e)
    {
        if (!IsInitialized || sender is not WpfRadioButton { Tag: string section }) return;
        ShowSection(section);
    }

    private void RequestLicenseActivation(object sender, RoutedEventArgs e)
    {
        var email = LicenseEmailBox.Text.Trim();
        if (!EmailAddress.LooksComplete(email))
        {
            ShowLicenseNotice(ResourceText("LicenseEmailInvalid"));
            LicenseEmailBox.Focus();
            return;
        }
        ClearLicenseNotice();
        LicenseActivationRequested?.Invoke(email);
    }

    private void UseLicenseKey(object sender, RoutedEventArgs e)
    {
        var key = LicenseKeyBox.Text.Trim();
        if (string.IsNullOrEmpty(key))
        {
            ShowLicenseNotice(ResourceText("LicenseKeyEmpty"));
            LicenseKeyBox.Focus();
            return;
        }
        ClearLicenseNotice();
        LicenseKeySubmitted?.Invoke(key);
    }

    private void RemoveLicense(object sender, RoutedEventArgs e)
    {
        var confirmation = System.Windows.MessageBox.Show(
            this,
            ResourceText("RemoveLicenseConfirmation"),
            ResourceText("RemoveLicenseConfirmationTitle"),
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (confirmation != MessageBoxResult.Yes) return;
        ClearLicenseNotice();
        LicenseRemovalRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OpenPrivacyDraft(object sender, RoutedEventArgs e) =>
        LegalDocumentRequested?.Invoke(LegalDocumentKind.Privacy);

    private void OpenTermsDraft(object sender, RoutedEventArgs e) =>
        LegalDocumentRequested?.Invoke(LegalDocumentKind.Terms);

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
    private void CheckForUpdates(object sender, RoutedEventArgs e) => UpdateCheckRequested?.Invoke(this, EventArgs.Empty);
    private void DownloadUpdate(object sender, RoutedEventArgs e) => UpdateDownloadRequested?.Invoke(this, EventArgs.Empty);
    private void InstallUpdate(object sender, RoutedEventArgs e) => UpdateInstallRequested?.Invoke(this, EventArgs.Empty);

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

internal enum LegalDocumentKind
{
    Privacy,
    Terms,
}

internal sealed record LicenseScreenState(
    EntitlementState State,
    string? DeviceId,
    string? DeviceError,
    bool AuthorityConfigured,
    bool ActivationConfigured,
    bool HasStoredLicenseToken);
