using System.Reflection;
using Witness.Core.Licensing;
using Witness.Platform.Windows.Licensing;

namespace Witness.App;

/// <summary>
/// Reads the closed-beta license authority and activation address from build
/// metadata. They are build-time inputs rather than user settings so an
/// installed copy cannot be redirected to a server chosen at runtime. Empty
/// values keep ordinary development and CI builds local-only.
/// </summary>
internal sealed record WindowsBetaLicenseConfiguration(
    LicenseAuthority Authority,
    Uri? ActivationEndpoint)
{
    private const string AuthorityKey = "WitnessBetaLicensePublicKey";
    private const string EndpointKey = "WitnessBetaActivationEndpoint";

    internal bool HasActivationEndpoint => ActivationEndpoint is not null;

    internal static WindowsBetaLicenseConfiguration Current() => FromValues(
        Metadata(AuthorityKey),
        Metadata(EndpointKey));

    internal static WindowsBetaLicenseConfiguration FromValues(
        string? publicKeyBase64,
        string? activationEndpoint)
    {
        var authority = LicenseAuthority.FromBase64(publicKeyBase64 ?? string.Empty);
        Uri? endpoint = null;
        if (Uri.TryCreate(activationEndpoint?.Trim(), UriKind.Absolute, out var candidate)
            && string.Equals(candidate.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            && string.IsNullOrEmpty(candidate.UserInfo)
            && string.IsNullOrEmpty(candidate.Query)
            && string.IsNullOrEmpty(candidate.Fragment)
            && string.Equals(candidate.AbsolutePath, "/v1/activate", StringComparison.Ordinal))
        {
            endpoint = candidate;
        }
        return new WindowsBetaLicenseConfiguration(authority, endpoint);
    }

    internal IActivationBackend CreateBackend(out HttpClientActivationTransport? transport)
    {
        if (ActivationEndpoint is null)
        {
            transport = null;
            return new UnconfiguredActivationBackend();
        }
        transport = new HttpClientActivationTransport();
        return new HttpActivationBackend(ActivationEndpoint, transport);
    }

    private static string? Metadata(string key) => typeof(WindowsBetaLicenseConfiguration).Assembly
        .GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(attribute => string.Equals(attribute.Key, key, StringComparison.Ordinal))
        ?.Value;
}
