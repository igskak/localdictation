using Microsoft.Win32;
using System.IO;

namespace Witness.Platform.Windows.Startup;

public interface IStartupValueStore
{
    string? Read(string valueName);
    void Write(string valueName, string value);
    void Delete(string valueName);
}

public sealed class CurrentUserRunValueStore : IStartupValueStore
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public string? Read(string valueName)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
        return key?.GetValue(valueName) as string;
    }

    public void Write(string valueName, string value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true)
            ?? throw new InvalidOperationException("The current-user startup registry key could not be opened.");
        key.SetValue(valueName, value, RegistryValueKind.String);
    }

    public void Delete(string valueName)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        key?.DeleteValue(valueName, throwOnMissingValue: false);
    }
}

public sealed class RunAtStartupService(IStartupValueStore store, string valueName, string executablePath)
{
    private readonly string command = QuoteExecutable(executablePath);

    public bool IsEnabled => string.Equals(store.Read(valueName), command, StringComparison.Ordinal);

    public void SetEnabled(bool enabled)
    {
        if (enabled)
        {
            store.Write(valueName, command);
            return;
        }

        // Never remove a value that another install or the user has replaced.
        if (IsEnabled) store.Delete(valueName);
    }

    internal static string QuoteExecutable(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (path.Contains('"', StringComparison.Ordinal))
            throw new ArgumentException("An executable path cannot contain a quote.", nameof(path));
        return $"\"{Path.GetFullPath(path)}\"";
    }
}
