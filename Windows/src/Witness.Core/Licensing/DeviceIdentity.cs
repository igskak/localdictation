using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Witness.Core.Licensing;

public static partial class DeviceIdentityDerivation
{
    // Part of the Windows identifier contract. Changing it would invalidate
    // every Windows key already issued, so it is intentionally platform-specific.
    private const string NamespaceSalt = "Witness.Windows.device.v1";

    public static bool TryDerive(string? hardwareUuid, out string deviceId)
    {
        deviceId = string.Empty;
        if (string.IsNullOrWhiteSpace(hardwareUuid)
            || !Guid.TryParse(hardwareUuid, out var uuid))
        {
            return false;
        }

        var normalized = uuid.ToString("N").ToLowerInvariant();
        if (normalized == Guid.Empty.ToString("N") || AllFPattern().IsMatch(normalized))
        {
            return false;
        }

        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(NamespaceSalt + normalized));
        deviceId = Convert.ToHexStringLower(digest.AsSpan(0, 16));
        return true;
    }

    public static bool IsValidDeviceId(string? value) => value is { Length: 32 }
        && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    [GeneratedRegex("^f{32}$", RegexOptions.CultureInvariant)]
    private static partial Regex AllFPattern();
}
