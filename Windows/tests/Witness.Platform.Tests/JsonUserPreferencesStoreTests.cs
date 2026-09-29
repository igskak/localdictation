using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Text.Json;
using Witness.Core.Audio;
using Witness.Core.Input;
using Witness.Core.Settings;
using Witness.Platform.Windows.Settings;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class JsonUserPreferencesStoreTests
{
    [TestMethod]
    public void RoundTripContainsOnlyEnumeratedNonContentFields()
    {
        var files = new MemoryFileSystem();
        var store = new JsonUserPreferencesStore(@"C:\Witness\settings.json", files);
        store.Save(new UserPreferences(
            true,
            ["uk", "en"],
            HotkeyActivationMode.Toggle,
            AudioInputSelection.Specific("synthetic-endpoint")));

        var loaded = store.Load();

        Assert.IsFalse(loaded.RecoveredFromInvalidData);
        CollectionAssert.AreEqual(new[] { "uk", "en" }, loaded.Preferences.LanguageCodes.ToArray());
        Assert.AreEqual(HotkeyActivationMode.Toggle, loaded.Preferences.ActivationMode);
        Assert.AreEqual("synthetic-endpoint", loaded.Preferences.AudioInput.DeviceId);
        var json = files.Files[@"C:\Witness\settings.json"];
        StringAssert.Contains(json, "\"schemaVersion\"");
        using var parsed = JsonDocument.Parse(json);
        CollectionAssert.AreEquivalent(
            new[]
            {
                "schemaVersion",
                "onboardingCompleted",
                "languageCodes",
                "activationMode",
                "audioInputKind",
                "audioInputDeviceId",
            },
            parsed.RootElement.EnumerateObject().Select(property => property.Name).ToArray());
        Assert.DoesNotContain("transcript", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("glossary", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("history", json, StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void InvalidDocumentFailsClosedToDefaults()
    {
        var files = new MemoryFileSystem();
        files.Files[@"C:\Witness\settings.json"] = "{ definitely-not-json";
        var result = new JsonUserPreferencesStore(@"C:\Witness\settings.json", files).Load();

        Assert.IsTrue(result.RecoveredFromInvalidData);
        Assert.AreEqual(UserPreferences.Default, result.Preferences);
    }

    private sealed class MemoryFileSystem : ISettingsFileSystem
    {
        public Dictionary<string, string> Files { get; } = new(StringComparer.Ordinal);
        public bool Exists(string path) => Files.ContainsKey(path);
        public string ReadAllText(string path) => Files[path];
        public void WriteAllText(string path, string contents) => Files[path] = contents;
        public void MoveReplacing(string source, string destination)
        {
            Files[destination] = Files[source];
            Files.Remove(source);
        }
        public void DeleteIfExists(string path) => Files.Remove(path);
    }
}
