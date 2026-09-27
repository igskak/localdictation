using System.Collections.ObjectModel;

namespace Witness.Update;

public sealed class UpdateTrustPolicy
{
    public UpdateTrustPolicy(
        Uri manifestUri,
        string packageId,
        string platform,
        string architecture,
        string channel,
        int productMajor,
        Version minimumOs,
        long maximumPackageBytes,
        IReadOnlyDictionary<string, byte[]> publicKeys,
        IEnumerable<string> allowedPackageHosts)
    {
        ArgumentNullException.ThrowIfNull(manifestUri);
        ArgumentNullException.ThrowIfNull(publicKeys);
        ArgumentNullException.ThrowIfNull(allowedPackageHosts);

        if (!IsTrustedHttpsUri(manifestUri, new[] { manifestUri.Host }))
        {
            throw new ArgumentException("The manifest endpoint must be an absolute HTTPS URL without credentials or a fragment.", nameof(manifestUri));
        }

        if (maximumPackageBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumPackageBytes));
        }

        ManifestUri = manifestUri;
        PackageId = RequireValue(packageId, nameof(packageId));
        Platform = RequireValue(platform, nameof(platform));
        Architecture = RequireValue(architecture, nameof(architecture));
        Channel = RequireValue(channel, nameof(channel));
        ProductMajor = productMajor > 0 ? productMajor : throw new ArgumentOutOfRangeException(nameof(productMajor));
        MinimumOs = minimumOs ?? throw new ArgumentNullException(nameof(minimumOs));
        MaximumPackageBytes = maximumPackageBytes;
        PublicKeys = new ReadOnlyDictionary<string, byte[]>(publicKeys.ToDictionary(
            pair => RequireValue(pair.Key, nameof(publicKeys)),
            pair => pair.Value?.ToArray() ?? throw new ArgumentException("A public key cannot be null.", nameof(publicKeys)),
            StringComparer.Ordinal));
        AllowedPackageHosts = new HashSet<string>(allowedPackageHosts.Select(host => RequireValue(host, nameof(allowedPackageHosts))), StringComparer.OrdinalIgnoreCase);

        if (PublicKeys.Count == 0)
        {
            throw new ArgumentException("At least one trusted update key is required.", nameof(publicKeys));
        }

        if (AllowedPackageHosts.Count == 0)
        {
            throw new ArgumentException("At least one package host is required.", nameof(allowedPackageHosts));
        }
    }

    public Uri ManifestUri { get; }
    public string PackageId { get; }
    public string Platform { get; }
    public string Architecture { get; }
    public string Channel { get; }
    public int ProductMajor { get; }
    public Version MinimumOs { get; }
    public long MaximumPackageBytes { get; }
    public IReadOnlyDictionary<string, byte[]> PublicKeys { get; }
    public IReadOnlySet<string> AllowedPackageHosts { get; }

    public bool IsAllowedPackageUri(Uri uri) => IsTrustedHttpsUri(uri, AllowedPackageHosts);

    private static string RequireValue(string value, string parameterName) =>
        string.IsNullOrWhiteSpace(value) ? throw new ArgumentException("Value cannot be empty.", parameterName) : value;

    private static bool IsTrustedHttpsUri(Uri uri, IEnumerable<string> hosts) =>
        uri.IsAbsoluteUri
        && uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
        && string.IsNullOrEmpty(uri.UserInfo)
        && string.IsNullOrEmpty(uri.Fragment)
        && hosts.Contains(uri.Host, StringComparer.OrdinalIgnoreCase);
}
