using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Text.RegularExpressions;
using Witness.Core.Audio;
using Witness.Core.Languages;
using Witness.Core.Review;
using Witness.Core.Settings;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class W5SettingsWindowTests
{
    [TestMethod]
    public void SettingsOnboardingResourcesAndKeyboardSurfaceRenderWithSyntheticState()
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
                var german = (ResourceDictionary)System.Windows.Application.LoadComponent(
                    new Uri("/Witness;component/Resources/Strings.de.xaml", UriKind.Relative));
                CollectionAssert.AreEquivalent(
                    english.Keys.Cast<object>().ToArray(),
                    german.Keys.Cast<object>().ToArray(),
                    "English and German UI resources must expose the same keys.");
                foreach (var key in english.Keys.Cast<object>())
                {
                    var englishText = Assert.IsInstanceOfType<string>(english[key]);
                    var germanText = Assert.IsInstanceOfType<string>(german[key]);
                    CollectionAssert.AreEquivalent(
                        FormatItems(englishText),
                        FormatItems(germanText),
                        $"English and German resource '{key}' must expose the same format items.");
                }
                Assert.AreEqual("2 ausgewählt", string.Format(
                    System.Globalization.CultureInfo.GetCultureInfo("de-DE"),
                    Assert.IsInstanceOfType<string>(german["SelectedCount"]),
                    2));
                application.Resources.MergedDictionaries.Insert(0, english);

                var window = new Witness.App.MainWindow();
                window.ApplyPreferences(UserPreferences.Default with { OnboardingCompleted = true }, launchAtStartup: false);
                AudioInputDevice[] syntheticInputs =
                [
                    new AudioInputDevice("synthetic-default", "Synthetic desktop microphone", true, true, true),
                    new AudioInputDevice("synthetic-usb", "Synthetic USB microphone", true, false, false),
                ];
                window.ShowAudioInputs(syntheticInputs, AudioInputSelection.BuiltIn);
                window.ShowAudioInputs(syntheticInputs, AudioInputSelection.Specific("synthetic-usb"));
                window.ShowGlossary(
                [
                    new GlossaryEntry("Müller", SpeechLanguage.German),
                    new GlossaryEntry("Witness", SpeechLanguage.English),
                ],
                "2 synthetic session terms");
                var navigation = FindVisualChildren<RadioButton>(window)
                    .Where(button => button.Tag is string)
                    .ToArray();
                Assert.HasCount(6, navigation);
                Assert.IsTrue(navigation.All(button => button.Focusable && button.MinHeight >= 44));

                var decorative = (Border)window.FindName("DecorativeOverlay");
                Assert.IsNotNull(decorative);
                Assert.IsFalse(decorative.IsHitTestVisible);

                var status = (TextBlock)window.FindName("StatusText");
                status.Text = "Synthetic local-only status";
                SaveEvidenceIfRequested(Render(window, new Size(760, 560), 96), "w5-settings-synthetic.png");
                Render(window, new Size(1225, 900), 120);

                var dictionaryNavigation = navigation.Single(button => string.Equals(button.Tag as string, "Dictionary", StringComparison.Ordinal));
                dictionaryNavigation.IsChecked = true;
                SaveEvidenceIfRequested(Render(window, new Size(980, 720), 120), "w5-dictionary-synthetic.png");

                var onboarding = (Grid)window.FindName("OnboardingPanel");
                onboarding.Visibility = Visibility.Visible;
                SaveEvidenceIfRequested(Render(window, new Size(760, 560), 144), "w5-onboarding-synthetic.png");
                Assert.IsTrue(FindVisualChildren<ScrollViewer>(window).Any());
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
            Name = "Witness W5 settings UI test",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        Assert.IsTrue(completed.Wait(TimeSpan.FromSeconds(20)), "The W5 settings UI harness did not complete.");
        if (failure is not null)
            throw new AssertFailedException($"The W5 settings UI harness failed: {failure}", failure);
    }

    private static RenderTargetBitmap Render(Window window, Size size, double dpi)
    {
        window.Measure(size);
        window.Arrange(new Rect(size));
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap(
            Math.Max(1, (int)Math.Ceiling(size.Width * dpi / 96)),
            Math.Max(1, (int)Math.Ceiling(size.Height * dpi / 96)),
            dpi,
            dpi,
            PixelFormats.Pbgra32);
        bitmap.Render(window);
        Assert.IsGreaterThan(0, bitmap.PixelWidth);
        Assert.IsGreaterThan(0, bitmap.PixelHeight);
        return bitmap;
    }

    private static void SaveEvidenceIfRequested(RenderTargetBitmap bitmap, string fileName)
    {
        if (!string.Equals(
            Environment.GetEnvironmentVariable("WITNESS_CAPTURE_UI_EVIDENCE"),
            "1",
            StringComparison.Ordinal)) return;

        var configuredDirectory = Environment.GetEnvironmentVariable("WITNESS_UI_EVIDENCE_DIRECTORY");
        var directory = string.IsNullOrWhiteSpace(configuredDirectory)
            ? Path.GetFullPath(Path.Combine("artifacts", "ui-evidence"))
            : Path.GetFullPath(configuredDirectory);
        Directory.CreateDirectory(directory);
        using var output = File.Create(Path.Combine(directory, fileName));
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        encoder.Save(output);
    }

    private static string[] FormatItems(string value) => Regex.Matches(value, @"\{\d+(?::[^}]*)?\}")
        .Select(match => match.Value)
        .Distinct(StringComparer.Ordinal)
        .Order(StringComparer.Ordinal)
        .ToArray();

    private static IEnumerable<T> FindVisualChildren<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is T match) yield return match;
            foreach (var descendant in FindVisualChildren<T>(child)) yield return descendant;
        }
    }
}
