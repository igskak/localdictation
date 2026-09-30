using System.Reflection;
using Witness.Core;
using Witness.Update;

namespace Witness.App;

/// <summary>
/// Fixed release configuration for the isolated Windows beta update channel.
/// Empty values keep ordinary development and CI builds entirely local-only.
/// </summary>
internal sealed record WindowsBetaUpdateConfiguration(
    UpdateTrustPolicy? Policy,
    string? Error)
{
    private const string KeyIdMetadata = "WitnessUpdateKeyId";
    private const string PublicKeyMetadata = "WitnessUpdateManifestPublicKey";
    private const string ManifestEndpointMetadata = "WitnessUpdateManifestEndpoint";
    private const string PackageHostsMetadata = "WitnessUpdatePackageHosts";

    internal bool IsConfigured => Policy is not null;

    internal static WindowsBetaUpdateConfiguration Current() => FromValues(
        Metadata(KeyIdMetadata),
        Metadata(PublicKeyMetadata),
        Metadata(ManifestEndpointMetadata),
        Metadata(PackageHostsMetadata));

    internal static WindowsBetaUpdateConfiguration FromValues(
        string? keyId,
        string? publicKeyBase64,
        string? manifestEndpoint,
        string? packageHosts)
    {
        var values = new[] { keyId, publicKeyBase64, manifestEndpoint, packageHosts };
        if (values.All(string.IsNullOrWhiteSpace))
            return new WindowsBetaUpdateConfiguration(null, null);
        if (values.Any(string.IsNullOrWhiteSpace))
            return new WindowsBetaUpdateConfiguration(null, "The Windows beta update configuration is incomplete.");

        try
        {
            var normalizedKeyId = keyId!.Trim();
            if (normalizedKeyId.Length is < 1 or > 80
                || normalizedKeyId.Any(character => !(char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-')))
                throw new FormatException("The update key ID is invalid.");
            var publicKey = Convert.FromBase64String(publicKeyBase64!.Trim());
            if (publicKey.Length != 32)
                throw new FormatException("The update public key must contain exactly 32 bytes.");
            if (!Uri.TryCreate(manifestEndpoint!.Trim(), UriKind.Absolute, out var endpoint))
                throw new FormatException("The update manifest endpoint is invalid.");
            if (!string.IsNullOrEmpty(endpoint.Query))
                throw new FormatException("The update manifest endpoint cannot contain a query.");
            var hosts = packageHosts!
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            if (hosts.Length == 0 || hosts.Any(host => Uri.CheckHostName(host) == UriHostNameType.Unknown))
                throw new FormatException("Update package hosts must be bare DNS names or IP addresses.");
            var policy = new UpdateTrustPolicy(
                endpoint,
                ProductMetadata.WindowsAppId,
                "windows",
                ProductMetadata.Architecture,
                ProductMetadata.Channel,
                ProductMetadata.ProductMajor,
                Version.Parse(ProductMetadata.MinimumWindowsVersion),
                2L * 1024 * 1024 * 1024,
                new Dictionary<string, byte[]>(StringComparer.Ordinal) { [normalizedKeyId] = publicKey },
                hosts);
            return new WindowsBetaUpdateConfiguration(policy, null);
        }
        catch (Exception error) when (error is FormatException or ArgumentException or OverflowException)
        {
            return new WindowsBetaUpdateConfiguration(null, error.Message);
        }
    }

    private static string? Metadata(string key) => typeof(WindowsBetaUpdateConfiguration).Assembly
        .GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(attribute => string.Equals(attribute.Key, key, StringComparison.Ordinal))
        ?.Value;
}
