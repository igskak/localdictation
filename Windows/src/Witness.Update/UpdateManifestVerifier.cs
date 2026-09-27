using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using NSec.Cryptography;
using Velopack;

namespace Witness.Update;

public sealed partial class UpdateManifestVerifier
{
    private const int EnvelopeSchema = 1;
    private const int ManifestSchema = 1;
    private const int MaximumEnvelopeBytes = 128 * 1024;
    private const int MaximumReleaseNotesCharacters = 16 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        TypeInfoResolver = UpdateJsonContext.Default,
    };

    public VerifiedUpdateManifest Verify(ReadOnlySpan<byte> envelopeUtf8, UpdateTrustPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (envelopeUtf8.IsEmpty || envelopeUtf8.Length > MaximumEnvelopeBytes)
        {
            throw new UpdateVerificationException("The update envelope has an invalid size.");
        }

        SignedUpdateEnvelope envelope;
        try
        {
            envelope = JsonSerializer.Deserialize<SignedUpdateEnvelope>(envelopeUtf8, JsonOptions)
                ?? throw new UpdateVerificationException("The update envelope is empty.");
        }
        catch (JsonException exception)
        {
            throw new UpdateVerificationException("The update envelope is not valid JSON.", exception);
        }

        if (envelope.Schema != EnvelopeSchema)
        {
            throw new UpdateVerificationException("The update envelope schema is not supported.");
        }

        if (!policy.PublicKeys.TryGetValue(envelope.KeyId, out var trustedKeyBytes))
        {
            throw new UpdateVerificationException("The update envelope uses an unknown key.");
        }

        var manifestBytes = DecodeBase64(envelope.Manifest, "manifest");
        var signatureBytes = DecodeBase64(envelope.Signature, "signature");

        try
        {
            var algorithm = SignatureAlgorithm.Ed25519;
            var publicKey = PublicKey.Import(algorithm, trustedKeyBytes, KeyBlobFormat.RawPublicKey);
            if (!algorithm.Verify(publicKey, manifestBytes, signatureBytes))
            {
                throw new UpdateVerificationException("The update manifest signature is invalid.");
            }
        }
        catch (CryptographicException exception)
        {
            throw new UpdateVerificationException("The trusted update key is invalid.", exception);
        }

        UpdateManifest manifest;
        try
        {
            manifest = JsonSerializer.Deserialize<UpdateManifest>(manifestBytes, JsonOptions)
                ?? throw new UpdateVerificationException("The signed update manifest is empty.");
        }
        catch (JsonException exception)
        {
            throw new UpdateVerificationException("The signed update manifest is not valid JSON.", exception);
        }

        ValidateManifest(manifest, policy);
        var packageUri = new Uri(manifest.ReleaseUrl, UriKind.Absolute);
        return new VerifiedUpdateManifest(manifest, packageUri, manifestBytes.ToArray(), envelope.KeyId);
    }

    private static void ValidateManifest(UpdateManifest manifest, UpdateTrustPolicy policy)
    {
        Require(manifest.Schema == ManifestSchema, "The update manifest schema is not supported.");
        Require(string.Equals(manifest.Platform, policy.Platform, StringComparison.Ordinal), "The update platform does not match this app.");
        Require(string.Equals(manifest.Architecture, policy.Architecture, StringComparison.Ordinal), "The update architecture does not match this app.");
        Require(string.Equals(manifest.Channel, policy.Channel, StringComparison.Ordinal), "The update channel does not match this app.");
        Require(string.Equals(manifest.PackageId, policy.PackageId, StringComparison.Ordinal), "The update package ID does not match this app.");
        Require(manifest.ProductMajor == policy.ProductMajor, "The update belongs to a different product major.");
        Require(manifest.Build > 0, "The update build must be positive.");
        Require(manifest.Size > 0 && manifest.Size <= policy.MaximumPackageBytes, "The update package size is outside the allowed range.");
        Require(Sha256Regex().IsMatch(manifest.Sha256), "The update package SHA-256 is malformed.");
        Require(SemanticVersion.TryParse(manifest.Version, out _), "The update version is malformed.");
        Require(Version.TryParse(manifest.MinimumOs, out var minimumOs) && minimumOs >= policy.MinimumOs, "The update minimum OS is malformed or below the supported product baseline.");
        Require(manifest.ReleaseNotes.Length <= MaximumReleaseNotesCharacters, "The update release notes are too long.");
        Require(Uri.TryCreate(manifest.ReleaseUrl, UriKind.Absolute, out var packageUri) && packageUri is not null && policy.IsAllowedPackageUri(packageUri), "The update package URL is not allowed.");
        if (packageUri is null)
        {
            throw new UpdateVerificationException("The update package URL is not allowed.");
        }
        Require(packageUri.AbsolutePath.EndsWith(".nupkg", StringComparison.OrdinalIgnoreCase), "The update package is not a full Velopack package.");
    }

    private static byte[] DecodeBase64(string value, string field)
    {
        try
        {
            return Convert.FromBase64String(value);
        }
        catch (FormatException exception)
        {
            throw new UpdateVerificationException($"The update {field} is not valid base64.", exception);
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new UpdateVerificationException(message);
        }
    }

    [GeneratedRegex("^[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex Sha256Regex();
}

public sealed class UpdateVerificationException : Exception
{
    public UpdateVerificationException(string message) : base(message) { }
    public UpdateVerificationException(string message, Exception innerException) : base(message, innerException) { }
}
