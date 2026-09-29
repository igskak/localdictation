using System.Globalization;
using System.Windows;

namespace Witness.App;

internal static class LocalizationResources
{
    private static readonly Uri English = new("Resources/Strings.en.xaml", UriKind.Relative);
    private static readonly Uri German = new("Resources/Strings.de.xaml", UriKind.Relative);

    internal static void UseCurrentCulture(ResourceDictionary resources)
    {
        ArgumentNullException.ThrowIfNull(resources);
        var localized = new ResourceDictionary
        {
            Source = string.Equals(CultureInfo.CurrentUICulture.TwoLetterISOLanguageName, "de", StringComparison.OrdinalIgnoreCase)
                ? German
                : English,
        };
        resources.MergedDictionaries.Insert(0, localized);
    }
}
