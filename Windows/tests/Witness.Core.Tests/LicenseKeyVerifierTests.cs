using System.Text;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Licensing;

namespace Witness.Core.Tests;

[TestClass]
public sealed class LicenseKeyVerifierTests
{
    private const string DifferentDevice = "ffffffffffffffffffffffffffffffff";

    [TestMethod]
    public void EveryLicenseKindIssuedByTheServiceVerifiesOffline()
    {
        var fixture = LoadFixture();
        var authority = LicenseAuthority.FromBase64(fixture.PublicKeyBase64);
        Assert.IsTrue(authority.IsConfigured);
        CollectionAssert.AreEquivalent(
            new[] { "trial", "annual", "lifetime" },
            fixture.Keys.Select(key => key.Kind).ToArray());

        var verifier = new LicenseKeyVerifier();
        foreach (var key in fixture.Keys)
        {
            var license = verifier.Verify(key.Token, authority, fixture.Device);
            Assert.AreEqual(key.Id, license.Id);
            Assert.AreEqual(fixture.Email, license.Email);
            Assert.AreEqual(fixture.Device, license.DeviceId);
            Assert.AreEqual(ParseKind(key.Kind), license.Kind);
            Assert.AreEqual(DateTimeOffset.FromUnixTimeSeconds(key.Issued), license.IssuedAt);
            Assert.AreEqual(key.Expires is long expiry ? DateTimeOffset.FromUnixTimeSeconds(expiry) : null, license.ExpiresAt);
        }
    }

    [TestMethod]
    public void ServiceKeyIsRejectedForAnotherComputer()
    {
        var fixture = LoadFixture();
        var exception = Assert.ThrowsExactly<LicenseKeyVerificationException>(() =>
            new LicenseKeyVerifier().Verify(
                fixture.Keys[0].Token,
                LicenseAuthority.FromBase64(fixture.PublicKeyBase64),
                DifferentDevice));

        Assert.AreEqual(LicenseKeyErrorKind.WrongDevice, exception.Kind);
    }

    [TestMethod]
    public void EditedPayloadIsRejectedBeforeItsFieldsAreTrusted()
    {
        var fixture = LoadFixture();
        var key = fixture.Keys.Single(candidate => candidate.Kind == "trial");
        var parts = key.Token.Split('.');
        var payload = Encoding.UTF8.GetString(DecodeBase64Url(parts[1]))
            .Replace("\"trial\"", "\"lifetime\"", StringComparison.Ordinal);
        var forged = $"{parts[0]}.{EncodeBase64Url(Encoding.UTF8.GetBytes(payload))}.{parts[2]}";

        var exception = Assert.ThrowsExactly<LicenseKeyVerificationException>(() =>
            new LicenseKeyVerifier().Verify(
                forged,
                LicenseAuthority.FromBase64(fixture.PublicKeyBase64),
                fixture.Device));

        Assert.AreEqual(LicenseKeyErrorKind.BadSignature, exception.Kind);
    }

    [TestMethod]
    public void UnconfiguredAuthorityFailsClosed()
    {
        var fixture = LoadFixture();
        var exception = Assert.ThrowsExactly<LicenseKeyVerificationException>(() =>
            new LicenseKeyVerifier().Verify(fixture.Keys[0].Token, LicenseAuthority.Unconfigured, fixture.Device));

        Assert.AreEqual(LicenseKeyErrorKind.NoAuthority, exception.Kind);
    }

    [TestMethod]
    [DataRow("")]
    [DataRow("LD1")]
    [DataRow("LD1.payload")]
    [DataRow("LD1.payload.signature.extra")]
    [DataRow("LD1.pay load.signature")]
    public void MalformedTokensAreRefused(string token)
    {
        var exception = Assert.ThrowsExactly<LicenseKeyVerificationException>(() =>
            new LicenseKeyVerifier().Verify(token, LicenseAuthority.Unconfigured, DifferentDevice));

        Assert.AreEqual(LicenseKeyErrorKind.Malformed, exception.Kind);
    }

    [TestMethod]
    public void UnknownPrefixIsReportedSeparately()
    {
        var exception = Assert.ThrowsExactly<LicenseKeyVerificationException>(() =>
            new LicenseKeyVerifier().Verify("LD2.payload.signature", LicenseAuthority.Unconfigured, DifferentDevice));

        Assert.AreEqual(LicenseKeyErrorKind.UnsupportedVersion, exception.Kind);
    }

    private static ParityFixture LoadFixture()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "activation-service-parity.json");
        return JsonSerializer.Deserialize<ParityFixture>(File.ReadAllBytes(path), new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        }) ?? throw new InvalidOperationException("The activation service parity fixture is empty.");
    }

    private static LicenseKind ParseKind(string value) => value switch
    {
        "trial" => LicenseKind.Trial,
        "annual" => LicenseKind.Annual,
        "lifetime" => LicenseKind.Lifetime,
        _ => throw new InvalidOperationException($"Unknown fixture license kind: {value}"),
    };

    private static byte[] DecodeBase64Url(string value)
    {
        var base64 = value.Replace('-', '+').Replace('_', '/');
        base64 = base64.PadRight(base64.Length + ((4 - base64.Length % 4) % 4), '=');
        return Convert.FromBase64String(base64);
    }

    private static string EncodeBase64Url(byte[] value) => Convert.ToBase64String(value)
        .TrimEnd('=')
        .Replace('+', '-')
        .Replace('/', '_');

    private sealed record ParityFixture(string Device, string Email, string PublicKeyBase64, ParityKey[] Keys);

    private sealed record ParityKey(string Kind, string Id, long Issued, long? Expires, string Token);
}
