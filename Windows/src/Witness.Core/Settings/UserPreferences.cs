using Witness.Core.Audio;
using Witness.Core.Input;
using Witness.Core.Languages;

namespace Witness.Core.Settings;

/// <summary>
/// Non-content choices that may survive a launch. Session glossary terms,
/// transcripts, history and diagnostics are deliberately absent.
/// </summary>
public sealed record UserPreferences(
    bool OnboardingCompleted,
    IReadOnlyList<string> LanguageCodes,
    HotkeyActivationMode ActivationMode,
    AudioInputSelection AudioInput,
    bool ProductEventSharingEnabled = true)
{
    public const int CurrentSchemaVersion = 2;

    public static UserPreferences Default { get; } = new(
        OnboardingCompleted: false,
        LanguageCodes: [SpeechLanguage.German.Code, SpeechLanguage.English.Code],
        ActivationMode: HotkeyActivationMode.Hold,
        AudioInput: AudioInputSelection.SystemDefault,
        ProductEventSharingEnabled: true);

    public UserPreferences Normalized()
    {
        var languages = (LanguageCodes ?? Array.Empty<string>())
            .Where(LanguageCatalog.ByCode.ContainsKey)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        if (languages.Length == 0)
        {
            languages = Default.LanguageCodes.ToArray();
        }

        var activation = Enum.IsDefined(ActivationMode)
            ? ActivationMode
            : HotkeyActivationMode.Hold;
        var audio = AudioInput switch
        {
            { Kind: AudioInputSelectionKind.Specific, DeviceId: not null } when
                !string.IsNullOrWhiteSpace(AudioInput.DeviceId) => AudioInput,
            { Kind: AudioInputSelectionKind.SystemDefault } => AudioInputSelection.SystemDefault,
            { Kind: AudioInputSelectionKind.BuiltIn } => AudioInputSelection.BuiltIn,
            _ => AudioInputSelection.SystemDefault,
        };
        return this with
        {
            LanguageCodes = languages,
            ActivationMode = activation,
            AudioInput = audio,
        };
    }

    public LanguageProfile LanguageProfile() => new(
        Normalized().LanguageCodes.Select(code => new SpeechLanguage(code)));
}
