#if WITNESS_W7_HARNESS
using System.IO;
using Velopack;
using Witness.Core.Audio;
using Witness.Core.Input;
using Witness.Core.Licensing;
using Witness.Core.Settings;
using Witness.Platform.Windows.Licensing;
using Witness.Platform.Windows.Settings;

namespace Witness.App;

/// <summary>
/// Compiled only into the CI A/B fixtures. It never exists in an ordinary or
/// distributable build and uses only fixed synthetic non-content state.
/// </summary>
internal static class W7PreservationHarness
{
    private static readonly DateTimeOffset Origin = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
    private static readonly byte[] SyntheticModel = [0x57, 0x37, 0x00, 0x01];

    internal static bool TryRun(string[] arguments, out int exitCode)
    {
        exitCode = 0;
        if (arguments.Length == 0 || !arguments[0].StartsWith("--w7-", StringComparison.Ordinal)) return false;
        try
        {
            switch (arguments[0])
            {
                case "--w7-seed-data" when arguments.Length == 2:
                    Seed(arguments[1]);
                    return true;
                case "--w7-apply-update" when arguments.Length == 4:
                    Apply(arguments[1], arguments[2], arguments[3]);
                    return true;
                case "--w7-verify-data" when arguments.Length == 3:
                    Verify(arguments[1], arguments[2]);
                    return true;
                default:
                    throw new ArgumentException("Invalid W7 CI harness arguments.");
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            exitCode = 1;
            return true;
        }
    }

    private static void Seed(string identityMarker)
    {
        var paths = WitnessLocalDataPaths.Current();
        new JsonUserPreferencesStore(paths.Settings).Save(new UserPreferences(
            true,
            ["uk", "en"],
            HotkeyActivationMode.Toggle,
            AudioInputSelection.Specific("synthetic-w7-endpoint"),
            ProductEventSharingEnabled: false));
        new JsonEntitlementStore(paths.License).Save(new UsageRecord(
            Origin,
            "synthetic-w7-install",
            Origin.AddMinutes(1),
            Origin.AddHours(1),
            LicenseToken: null));
        Directory.CreateDirectory(paths.Models);
        File.WriteAllBytes(Path.Combine(paths.Models, "synthetic-w7-model.bin"), SyntheticModel);
        File.WriteAllText(Path.GetFullPath(identityMarker), IdentityObservation());
    }

    private static void Apply(string feedDirectory, string successMarker, string identityMarker)
    {
        var manager = new UpdateManager(
            Path.GetFullPath(feedDirectory),
            new UpdateOptions
            {
                AllowVersionDowngrade = false,
                ExplicitChannel = "beta",
                MaximumDeltasBeforeFallback = -1,
            });
        var update = manager.CheckForUpdates()
            ?? throw new InvalidOperationException("The synthetic B package was not available to installed A.");
        manager.DownloadUpdates(update, _ => { });
        manager.WaitExitThenApplyUpdates(
            update.TargetFullRelease,
            silent: true,
            restart: true,
            restartArgs:
            [
                "--w7-verify-data",
                Path.GetFullPath(successMarker),
                Path.GetFullPath(identityMarker),
            ]);
    }

    private static void Verify(string successMarker, string identityMarker)
    {
        var identity = WindowsBuildIdentity.Current();
        if (!string.Equals(identity.Version, "0.1.1", StringComparison.Ordinal) || identity.Build != 102)
            throw new InvalidOperationException("The updater did not restart the expected synthetic B build.");
        var paths = WitnessLocalDataPaths.Current();
        var settings = new JsonUserPreferencesStore(paths.Settings).Load();
        if (settings.RecoveredFromInvalidData
            || !settings.Preferences.OnboardingCompleted
            || !settings.Preferences.LanguageCodes.SequenceEqual(["uk", "en"])
            || settings.Preferences.ActivationMode != HotkeyActivationMode.Toggle
            || settings.Preferences.AudioInput != AudioInputSelection.Specific("synthetic-w7-endpoint")
            || settings.Preferences.ProductEventSharingEnabled)
            throw new InvalidOperationException("Synthetic settings did not survive A to B.");
        var entitlement = new JsonEntitlementStore(paths.License).Load();
        if (entitlement is null
            || entitlement.InstallId != "synthetic-w7-install"
            || entitlement.FirstDictationAt != Origin.AddMinutes(1))
            throw new InvalidOperationException("Synthetic entitlement did not survive A to B.");
        var model = File.ReadAllBytes(Path.Combine(paths.Models, "synthetic-w7-model.bin"));
        if (!model.SequenceEqual(SyntheticModel))
            throw new InvalidOperationException("The unchanged synthetic model was not preserved.");
        if (File.Exists(Path.Combine(paths.Root, "glossary.json")))
            throw new InvalidOperationException("A forbidden glossary handoff file was created.");
        var expectedIdentity = File.ReadAllText(Path.GetFullPath(identityMarker));
        if (!string.Equals(expectedIdentity, IdentityObservation(), StringComparison.Ordinal))
            throw new InvalidOperationException("The hardware-identity result changed across the installed lifecycle.");
        File.WriteAllText(Path.GetFullPath(successMarker), "W7_A_TO_B_PRESERVED");
    }

    private static string IdentityObservation()
    {
        var identity = new WindowsHardwareDeviceIdentity().Resolve();
        return identity.DeviceId ?? "unavailable";
    }
}
#endif
