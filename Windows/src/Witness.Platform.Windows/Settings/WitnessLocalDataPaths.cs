using System.IO;

namespace Witness.Platform.Windows.Settings;

public sealed record WitnessLocalDataPaths(
    string Root,
    string Settings,
    string License,
    string Models)
{
    public static WitnessLocalDataPaths Current()
    {
        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localData))
            throw new InvalidOperationException("Windows did not provide a local application-data directory.");
        return FromLocalApplicationData(localData);
    }

    public static WitnessLocalDataPaths FromLocalApplicationData(string localApplicationData)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(localApplicationData);
        var root = Path.Combine(Path.GetFullPath(localApplicationData), "Witness");
        return new WitnessLocalDataPaths(
            root,
            Path.Combine(root, "settings.json"),
            Path.Combine(root, "license.json"),
            Path.Combine(root, "Models"));
    }
}
