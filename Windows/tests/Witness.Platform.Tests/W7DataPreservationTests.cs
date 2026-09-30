using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Audio;
using Witness.Core.Input;
using Witness.Core.Licensing;
using Witness.Core.Settings;
using Witness.Platform.Windows.Licensing;
using Witness.Platform.Windows.Settings;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class W7DataPreservationTests
{
    private static readonly DateTimeOffset Origin = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

    [TestMethod]
    public void AppReplacementUninstallAndReinstallPreserveAllowlistedLocalData()
    {
        var temporaryRoot = Path.Combine(Path.GetTempPath(), "witness-w7-preservation", Guid.NewGuid().ToString("N"));
        var appDirectory = Path.Combine(temporaryRoot, "installed-app");
        var localApplicationData = Path.Combine(temporaryRoot, "local-data");
        var paths = WitnessLocalDataPaths.FromLocalApplicationData(localApplicationData);
        try
        {
            Directory.CreateDirectory(appDirectory);
            File.WriteAllText(Path.Combine(appDirectory, "version.txt"), "A");
            var preferences = new UserPreferences(
                true,
                ["uk", "en"],
                HotkeyActivationMode.Toggle,
                AudioInputSelection.Specific("synthetic-endpoint"),
                ProductEventSharingEnabled: false);
            new JsonUserPreferencesStore(paths.Settings).Save(preferences);
            var entitlement = new UsageRecord(
                Origin,
                "synthetic-install-id",
                Origin.AddMinutes(1),
                Origin.AddHours(1),
                "LD1.synthetic.non-secret");
            new JsonEntitlementStore(paths.License).Save(entitlement);
            Directory.CreateDirectory(paths.Models);
            var modelPath = Path.Combine(paths.Models, "synthetic-model.bin");
            File.WriteAllBytes(modelPath, [0x57, 0x37, 0x00, 0x01]);
            var modelHash = SHA256.HashData(File.ReadAllBytes(modelPath));
            var identityA = new WindowsHardwareDeviceIdentity(new FixedProvider(RawTable())).Resolve();

            // Simulate replacing installed A with B. The installer owns only its
            // app directory; user data and the model live under local app data.
            Directory.Delete(appDirectory, recursive: true);
            Directory.CreateDirectory(appDirectory);
            File.WriteAllText(Path.Combine(appDirectory, "version.txt"), "B");

            var loadedPreferences = new JsonUserPreferencesStore(paths.Settings).Load();
            var loadedEntitlement = new JsonEntitlementStore(paths.License).Load();
            var identityB = new WindowsHardwareDeviceIdentity(new FixedProvider(RawTable())).Resolve();
            Assert.AreEqual("B", File.ReadAllText(Path.Combine(appDirectory, "version.txt")));
            CollectionAssert.AreEqual(
                preferences.Normalized().LanguageCodes.ToArray(),
                loadedPreferences.Preferences.LanguageCodes.ToArray());
            Assert.AreEqual(preferences.ActivationMode, loadedPreferences.Preferences.ActivationMode);
            Assert.AreEqual(preferences.AudioInput, loadedPreferences.Preferences.AudioInput);
            Assert.AreEqual(preferences.ProductEventSharingEnabled, loadedPreferences.Preferences.ProductEventSharingEnabled);
            Assert.AreEqual(entitlement, loadedEntitlement);
            CollectionAssert.AreEqual(modelHash, SHA256.HashData(File.ReadAllBytes(modelPath)));
            Assert.AreEqual(identityA.DeviceId, identityB.DeviceId);

            // Uninstall keeps local data and never performs remote license release.
            Directory.Delete(appDirectory, recursive: true);
            Assert.IsTrue(File.Exists(paths.Settings));
            Assert.IsTrue(File.Exists(paths.License));
            Assert.IsTrue(File.Exists(modelPath));

            // Vocabulary remains RAM-only by policy, so preservation must not
            // create a glossary handoff file during update or reinstall.
            Assert.IsFalse(File.Exists(Path.Combine(paths.Root, "glossary.json")));
        }
        finally
        {
            if (Directory.Exists(temporaryRoot)) Directory.Delete(temporaryRoot, recursive: true);
        }
    }

    private static byte[] RawTable()
    {
        var uuid = Guid.Parse("00112233-4455-6677-8899-aabbccddeeff").ToByteArray();
        var typeOne = new byte[26];
        typeOne[0] = 1;
        typeOne[1] = 24;
        uuid.CopyTo(typeOne, 8);
        var raw = new byte[8 + typeOne.Length];
        raw[1] = 3;
        raw[2] = 5;
        BinaryPrimitives.WriteUInt32LittleEndian(raw.AsSpan(4, 4), (uint)typeOne.Length);
        typeOne.CopyTo(raw, 8);
        return raw;
    }

    private sealed class FixedProvider(byte[] value) : IRawSmbiosProvider
    {
        public byte[] Read() => value;
    }
}
