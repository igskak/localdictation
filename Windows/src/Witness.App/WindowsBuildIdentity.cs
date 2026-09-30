using System.Reflection;
using Velopack;
using Witness.Core;

namespace Witness.App;

internal sealed record WindowsBuildIdentity(string Version, int Build)
{
    private const string BuildMetadata = "WitnessBuildNumber";

    internal static WindowsBuildIdentity Current()
    {
        var assembly = typeof(WindowsBuildIdentity).Assembly;
        var informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        var version = informational?.Split('+', 2)[0] ?? ProductMetadata.Version;
        var buildValue = assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => string.Equals(attribute.Key, BuildMetadata, StringComparison.Ordinal))
            ?.Value;
        return FromValues(version, buildValue);
    }

    internal static WindowsBuildIdentity FromValues(string? version, string? build)
    {
        var normalizedVersion = version?.Trim().Split('+', 2)[0];
        if (!SemanticVersion.TryParse(normalizedVersion, out _))
            normalizedVersion = ProductMetadata.Version;
        var normalizedBuild = int.TryParse(build, out var parsed) && parsed > 0
            ? parsed
            : ProductMetadata.Build;
        return new WindowsBuildIdentity(normalizedVersion!, normalizedBuild);
    }
}
