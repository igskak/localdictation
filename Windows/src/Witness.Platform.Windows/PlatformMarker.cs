namespace Witness.Platform.Windows;

public static class PlatformMarker
{
    public static bool IsSupportedOperatingSystem => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100);
}
