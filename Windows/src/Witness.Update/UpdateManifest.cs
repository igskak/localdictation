using System.Text.Json.Serialization;

namespace Witness.Update;

public sealed record SignedUpdateEnvelope
{
    public required int Schema { get; init; }
    public required string KeyId { get; init; }
    public required string Manifest { get; init; }
    public required string Signature { get; init; }
}

public sealed record UpdateManifest
{
    public required int Schema { get; init; }
    public required string Platform { get; init; }
    public required string Architecture { get; init; }
    public required string Channel { get; init; }
    public required string PackageId { get; init; }
    public required string Version { get; init; }
    public required int Build { get; init; }
    public required string ReleaseUrl { get; init; }
    public required long Size { get; init; }
    public required string Sha256 { get; init; }
    public required string MinimumOs { get; init; }
    public required int ProductMajor { get; init; }
    public required string ReleaseNotes { get; init; }
}

public sealed record VerifiedUpdateManifest(
    UpdateManifest Manifest,
    Uri PackageUri,
    byte[] SignedManifestBytes,
    string KeyId);

[JsonSerializable(typeof(SignedUpdateEnvelope))]
[JsonSerializable(typeof(UpdateManifest))]
internal sealed partial class UpdateJsonContext : JsonSerializerContext;
