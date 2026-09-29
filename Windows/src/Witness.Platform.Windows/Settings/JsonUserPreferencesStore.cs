using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Witness.Core.Audio;
using Witness.Core.Input;
using Witness.Core.Settings;

namespace Witness.Platform.Windows.Settings;

public sealed record SettingsLoadResult(UserPreferences Preferences, bool RecoveredFromInvalidData);

public interface IUserPreferencesStore
{
    SettingsLoadResult Load();
    void Save(UserPreferences preferences);
}

public interface ISettingsFileSystem
{
    bool Exists(string path);
    string ReadAllText(string path);
    void WriteAllText(string path, string contents);
    void MoveReplacing(string source, string destination);
    void DeleteIfExists(string path);
}

public sealed class LocalSettingsFileSystem : ISettingsFileSystem
{
    public bool Exists(string path) => File.Exists(path);
    public string ReadAllText(string path) => File.ReadAllText(path);

    public void WriteAllText(string path, string contents)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)
            ?? throw new ArgumentException("A settings directory is required.", nameof(path)));
        File.WriteAllText(path, contents);
    }

    public void MoveReplacing(string source, string destination) => File.Move(source, destination, overwrite: true);

    public void DeleteIfExists(string path)
    {
        if (File.Exists(path)) File.Delete(path);
    }
}

/// <summary>
/// Persists only non-content preferences. The fixed document shape prevents a
/// future app object from accidentally serializing transcript or vocabulary
/// state just because it was added as a property.
/// </summary>
public sealed class JsonUserPreferencesStore : IUserPreferencesStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly string path;
    private readonly ISettingsFileSystem fileSystem;

    public JsonUserPreferencesStore(string path, ISettingsFileSystem? fileSystem = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        this.path = Path.GetFullPath(path);
        this.fileSystem = fileSystem ?? new LocalSettingsFileSystem();
    }

    public static string DefaultPath()
    {
        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localData))
            throw new InvalidOperationException("Windows did not provide a local application-data directory.");
        return Path.Combine(localData, "Witness", "settings.json");
    }

    public SettingsLoadResult Load()
    {
        if (!fileSystem.Exists(path))
            return new SettingsLoadResult(UserPreferences.Default, RecoveredFromInvalidData: false);

        try
        {
            var document = JsonSerializer.Deserialize<PreferencesDocument>(fileSystem.ReadAllText(path), JsonOptions);
            if (document is null || document.SchemaVersion != UserPreferences.CurrentSchemaVersion)
                return new SettingsLoadResult(UserPreferences.Default, RecoveredFromInvalidData: true);
            var preferences = new UserPreferences(
                document.OnboardingCompleted,
                document.LanguageCodes ?? [],
                document.ActivationMode,
                document.AudioInputKind == AudioInputSelectionKind.Specific
                    ? AudioInputSelection.Specific(document.AudioInputDeviceId ?? string.Empty)
                    : document.AudioInputKind == AudioInputSelectionKind.BuiltIn
                        ? AudioInputSelection.BuiltIn
                        : AudioInputSelection.SystemDefault);
            return new SettingsLoadResult(preferences.Normalized(), RecoveredFromInvalidData: false);
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            return new SettingsLoadResult(UserPreferences.Default, RecoveredFromInvalidData: true);
        }
    }

    public void Save(UserPreferences preferences)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        var normalized = preferences.Normalized();
        var document = new PreferencesDocument(
            UserPreferences.CurrentSchemaVersion,
            normalized.OnboardingCompleted,
            normalized.LanguageCodes.ToArray(),
            normalized.ActivationMode,
            normalized.AudioInput.Kind,
            normalized.AudioInput.Kind == AudioInputSelectionKind.Specific
                ? normalized.AudioInput.DeviceId
                : null);
        var temporaryPath = string.Concat(path, ".tmp");
        try
        {
            fileSystem.WriteAllText(temporaryPath, JsonSerializer.Serialize(document, JsonOptions));
            fileSystem.MoveReplacing(temporaryPath, path);
        }
        finally
        {
            fileSystem.DeleteIfExists(temporaryPath);
        }
    }

    private sealed record PreferencesDocument(
        int SchemaVersion,
        bool OnboardingCompleted,
        string[]? LanguageCodes,
        HotkeyActivationMode ActivationMode,
        AudioInputSelectionKind AudioInputKind,
        string? AudioInputDeviceId);
}
