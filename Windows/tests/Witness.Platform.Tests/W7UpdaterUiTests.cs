using System.Windows;
using System.Windows.Controls;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Update;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class W7UpdaterUiTests
{
    [TestMethod]
    public void UpdateConfigurationIsAllOrNothingAndSeparatesTrustInputs()
    {
        var publicKey = Convert.ToBase64String(Enumerable.Range(0, 32).Select(value => (byte)value).ToArray());
        var configured = Witness.App.WindowsBetaUpdateConfiguration.FromValues(
            "windows-beta-update-2026-01",
            publicKey,
            "https://updates.example.invalid/beta/v1/envelope.json",
            "packages.example.invalid,cdn.example.invalid");

        Assert.IsTrue(configured.IsConfigured);
        Assert.IsNull(configured.Error);
        Assert.AreEqual("Witness.Windows.Beta", configured.Policy!.PackageId);
        Assert.AreEqual("beta", configured.Policy.Channel);
        Assert.IsTrue(configured.Policy.AllowedPackageHosts.SetEquals(
            ["packages.example.invalid", "cdn.example.invalid"]));

        Assert.IsFalse(Witness.App.WindowsBetaUpdateConfiguration.FromValues(null, null, null, null).IsConfigured);
        Assert.IsNotNull(Witness.App.WindowsBetaUpdateConfiguration.FromValues(
            "windows-beta-update-2026-01",
            publicKey,
            null,
            "packages.example.invalid").Error);
        Assert.IsNotNull(Witness.App.WindowsBetaUpdateConfiguration.FromValues(
            "windows-beta-update-2026-01",
            publicKey,
            "https://updates.example.invalid/beta/v1/envelope.json?device=forbidden",
            "packages.example.invalid").Error);
        Assert.IsNotNull(Witness.App.WindowsBetaUpdateConfiguration.FromValues(
            "windows-beta-update-2026-01",
            publicKey,
            "https://updates.example.invalid/beta/v1/envelope.json",
            "https://packages.example.invalid/path").Error);
    }

    [TestMethod]
    public void PackagedVersionAndBuildIdentityFailToSafeDefaults()
    {
        Assert.AreEqual(
            new Witness.App.WindowsBuildIdentity("0.1.1", 42),
            Witness.App.WindowsBuildIdentity.FromValues("0.1.1+ci.42", "42"));
        Assert.AreEqual(
            new Witness.App.WindowsBuildIdentity("0.1.0", 1),
            Witness.App.WindowsBuildIdentity.FromValues("not-semver", "0"));
    }

    [TestMethod]
    public void ManualUpdateSurfaceRequiresExplicitCheckDownloadAndInstallActions()
    {
        Exception? failure = null;
        var completed = new ManualResetEventSlim(false);
        var thread = new Thread(() =>
        {
            try
            {
                var application = System.Windows.Application.Current as Witness.App.App ?? new Witness.App.App();
                application.InitializeComponent();
                var english = (ResourceDictionary)System.Windows.Application.LoadComponent(
                    new Uri("/Witness;component/Resources/Strings.en.xaml", UriKind.Relative));
                application.Resources.MergedDictionaries.Insert(0, english);
                var window = new Witness.App.MainWindow();
                var check = (Button)window.FindName("CheckForUpdatesButton");
                var download = (Button)window.FindName("DownloadUpdateButton");
                var install = (Button)window.FindName("InstallUpdateButton");

                window.ShowUpdateState(AppUpdateSnapshot.Idle, configured: false, "0.1.0", 1);
                Assert.IsFalse(check.IsEnabled);
                Assert.AreEqual(Visibility.Collapsed, download.Visibility);
                Assert.AreEqual(Visibility.Collapsed, install.Visibility);

                window.ShowUpdateState(new AppUpdateSnapshot(
                    AppUpdateState.Available,
                    "0.1.1",
                    2,
                    "Synthetic plain-text release notes."), configured: true, "0.1.0", 1);
                Assert.IsTrue(check.IsEnabled);
                Assert.AreEqual(Visibility.Visible, download.Visibility);
                Assert.AreEqual(Visibility.Collapsed, install.Visibility);

                window.ShowUpdateState(new AppUpdateSnapshot(
                    AppUpdateState.ReadyToInstall,
                    "0.1.1",
                    2,
                    "Synthetic plain-text release notes.",
                    100), configured: true, "0.1.0", 1);
                Assert.AreEqual(Visibility.Collapsed, download.Visibility);
                Assert.AreEqual(Visibility.Visible, install.Visibility);
                Assert.IsTrue(install.IsEnabled);
                window.Close();
            }
            catch (Exception error)
            {
                failure = error;
            }
            finally
            {
                completed.Set();
            }
        })
        {
            IsBackground = true,
            Name = "Witness W7 updater UI test",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        Assert.IsTrue(completed.Wait(TimeSpan.FromSeconds(20)), "The W7 updater UI harness did not complete.");
        if (failure is not null)
            throw new AssertFailedException($"The W7 updater UI harness failed: {failure}", failure);
    }
}
