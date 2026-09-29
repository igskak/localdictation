using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using NSec.Cryptography;

namespace Witness.Core.Licensing;

public enum LicenseKeyErrorKind
{
    Malformed,
    UnsupportedVersion,
    NoAuthority,
    BadSignature,
    WrongDevice,
    InconsistentDates,
}

public sealed class LicenseKeyVerificationException : Exception
{
    public LicenseKeyVerificationException(LicenseKeyErrorKind kind, string message)
        : base(message)
    {
        Kind = kind;
    }

    public LicenseKeyVerificationException(LicenseKeyErrorKind kind, string message, Exception innerException)
        : base(message, innerException)
    {
        Kind = kind;
    }

    public LicenseKeyErrorKind Kind { get; }
}

public sealed class LicenseAuthority
{
    private LicenseAuthority(byte[]? publicKeyBytes)
    {
        PublicKeyBytes = publicKeyBytes;
    }

    internal byte[]? PublicKeyBytes { get; }

    public bool IsConfigured => PublicKeyBytes is not null;

    public static LicenseAuthority FromBase64(string publicKeyBase64)
    {
        if (string.IsNullOrWhiteSpace(publicKeyBase64))
        {
            return new LicenseAuthority(null);
        }

        try
        {
            var bytes = Convert.FromBase64String(publicKeyBase64);
            return bytes.Length == 32
                ? new LicenseAuthority(bytes)
                : new LicenseAuthority(null);
        }
        catch (FormatException)
        {
            return new LicenseAuthority(null);
        }
    }

    public static LicenseAuthority Unconfigured { get; } = new(null);
}

/// <summary>
/// Verifies LD1 licenses against an injected Ed25519 authority without any
/// network access. The signature covers the decoded payload bytes exactly as
/// issued; the JSON is not trusted or parsed until that signature succeeds.
/// </summary>
public sealed class LicenseKeyVerifier
{
    public const string Prefix = "LD1";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public License Verify(string token, LicenseAuthority authority, string deviceId)
    {
        ArgumentNullException.ThrowIfNull(token);
        ArgumentNullException.ThrowIfNull(authority);
        ArgumentNullException.ThrowIfNull(deviceId);

        var parts = token.Trim().Split('.', StringSplitOptions.None);
        if (parts.Length != 3 || parts[1].Length == 0 || parts[2].Length == 0)
        {
            throw Failure(LicenseKeyErrorKind.Malformed, "The license key is malformed.");
        }
        if (!string.Equals(parts[0], Prefix, StringComparison.Ordinal))
        {
            throw Failure(LicenseKeyErrorKind.UnsupportedVersion, "The license key version is not supported.");
        }

        var payloadBytes = DecodeBase64Url(parts[1]);
        var signatureBytes = DecodeBase64Url(parts[2]);
        var authorityBytes = authority.PublicKeyBytes;
        if (authorityBytes is null)
        {
            throw Failure(LicenseKeyErrorKind.NoAuthority, "This build has no license authority.");
        }

        try
        {
            var algorithm = SignatureAlgorithm.Ed25519;
            var publicKey = PublicKey.Import(algorithm, authorityBytes, KeyBlobFormat.RawPublicKey);
            if (!algorithm.Verify(publicKey, payloadBytes, signatureBytes))
            {
                throw Failure(LicenseKeyErrorKind.BadSignature, "The license key signature is invalid.");
            }
        }
        catch (CryptographicException exception)
        {
            throw new LicenseKeyVerificationException(
                LicenseKeyErrorKind.NoAuthority,
                "The license authority is invalid.",
                exception);
        }

        LicensePayload payload;
        try
        {
            payload = JsonSerializer.Deserialize<LicensePayload>(payloadBytes, JsonOptions)
                ?? throw Failure(LicenseKeyErrorKind.Malformed, "The license payload is empty.");
        }
        catch (JsonException exception)
        {
            throw new LicenseKeyVerificationException(
                LicenseKeyErrorKind.Malformed,
                "The license payload is malformed.",
                exception);
        }

        var kind = ParseKind(payload.Kind);
        var issuedAt = ParseTimestamp(payload.Issued);
        var expiresAt = payload.Expires is double expiry ? ParseTimestamp(expiry) : (DateTimeOffset?)null;
        var isDated = kind is LicenseKind.Trial or LicenseKind.Annual;
        if (isDated != (expiresAt is not null) || expiresAt <= issuedAt)
        {
            throw Failure(LicenseKeyErrorKind.InconsistentDates, "The license dates are inconsistent.");
        }
        if (!string.Equals(payload.Device, deviceId, StringComparison.Ordinal))
        {
            throw Failure(LicenseKeyErrorKind.WrongDevice, "The license belongs to a different computer.");
        }

        return new License(payload.Id, payload.Email, kind, payload.Device, issuedAt, expiresAt);
    }

    private static LicenseKind ParseKind(string kind) => kind switch
    {
        "trial" => LicenseKind.Trial,
        "annual" => LicenseKind.Annual,
        "lifetime" => LicenseKind.Lifetime,
        _ => throw Failure(LicenseKeyErrorKind.Malformed, "The license kind is not supported."),
    };

    private static DateTimeOffset ParseTimestamp(double timestamp)
    {
        if (!double.IsFinite(timestamp))
        {
            throw Failure(LicenseKeyErrorKind.InconsistentDates, "The license date is invalid.");
        }

        try
        {
            return DateTimeOffset.UnixEpoch.AddSeconds(timestamp);
        }
        catch (ArgumentOutOfRangeException exception)
        {
            throw new LicenseKeyVerificationException(
                LicenseKeyErrorKind.InconsistentDates,
                "The license date is outside the supported range.",
                exception);
        }
    }

    private static byte[] DecodeBase64Url(string value)
    {
        if (value.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not '-' and not '_'))
        {
            throw Failure(LicenseKeyErrorKind.Malformed, "The license key encoding is malformed.");
        }

        var base64 = value.Replace('-', '+').Replace('_', '/');
        if (base64.Length % 4 == 1)
        {
            throw Failure(LicenseKeyErrorKind.Malformed, "The license key encoding is malformed.");
        }
        base64 = base64.PadRight(base64.Length + ((4 - base64.Length % 4) % 4), '=');
        try
        {
            return Convert.FromBase64String(base64);
        }
        catch (FormatException exception)
        {
            throw new LicenseKeyVerificationException(
                LicenseKeyErrorKind.Malformed,
                "The license key encoding is malformed.",
                exception);
        }
    }

    private static LicenseKeyVerificationException Failure(LicenseKeyErrorKind kind, string message) => new(kind, message);

    private sealed class LicensePayload
    {
        [JsonPropertyName("id"), JsonRequired]
        public required string Id { get; init; }

        [JsonPropertyName("email"), JsonRequired]
        public required string Email { get; init; }

        [JsonPropertyName("kind"), JsonRequired]
        public required string Kind { get; init; }

        [JsonPropertyName("device"), JsonRequired]
        public required string Device { get; init; }

        [JsonPropertyName("issued"), JsonRequired]
        public required double Issued { get; init; }

        [JsonPropertyName("expires")]
        public double? Expires { get; init; }
    }
}
