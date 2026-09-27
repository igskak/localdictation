using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using NSec.Cryptography;
using Velopack;

namespace Witness.Update.Tests;

[TestClass]
public sealed class VerifiedManifestUpdateSourceTests
{
    private const string PackageId = "Witness.Windows.Beta";
    private const string KeyId = "windows-beta-2026-01";
    private static readonly Uri ManifestUri = new("https://updates.test.invalid/beta/v1/envelope.json");

    [TestMethod]
    [DataRow("0.1.0", 1)]
    [DataRow("0.1.1", 2)]
    public async Task SignedManifestBecomesVerifiedVelopackFeedAndPackage(string version, int build)
    {
        using var authority = new TestAuthority();
        var package = Encoding.UTF8.GetBytes($"synthetic package {version}/{build}");
        var packageUri = new Uri($"https://packages.test.invalid/Witness-{version}-full.nupkg");
        var manifest = CreateManifest(version, build, packageUri, package);
        var envelope = authority.Sign(manifest);
        using var http = new HttpClient(new RouteHandler(new Dictionary<Uri, byte[]>
        {
            [ManifestUri] = envelope,
            [packageUri] = package,
        }));
        using var source = new VerifiedManifestUpdateSource(CreatePolicy(authority.PublicKey), httpClient: http);

        var feed = await source.GetReleaseFeed(null!, PackageId, "beta");

        Assert.HasCount(1, feed.Assets);
        var asset = feed.Assets[0];
        Assert.AreEqual(version, asset.Version.ToNormalizedString());
        Assert.AreEqual(VelopackAssetType.Full, asset.Type);
        Assert.AreEqual(manifest.Sha256, asset.SHA256);
        Assert.AreEqual(manifest.Size, asset.Size);

        var directory = Path.Combine(Path.GetTempPath(), "witness-update-tests", Guid.NewGuid().ToString("N"));
        var destination = Path.Combine(directory, asset.FileName);
        try
        {
            var progress = new List<int>();
            await source.DownloadReleaseEntry(null!, asset, destination, progress.Add);
            CollectionAssert.AreEqual(package, await File.ReadAllBytesAsync(destination));
            Assert.AreEqual(100, progress[^1]);
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [TestMethod]
    public void SignatureCoversTheOriginalManifestBytes()
    {
        using var authority = new TestAuthority();
        var package = Encoding.UTF8.GetBytes("synthetic package");
        var manifest = CreateManifest("0.1.0", 1, new Uri("https://packages.test.invalid/Witness-0.1.0-full.nupkg"), package);
        var envelopeBytes = authority.Sign(manifest);
        var envelope = JsonSerializer.Deserialize<SignedUpdateEnvelope>(envelopeBytes, JsonOptions())!;
        var signedBytes = Convert.FromBase64String(envelope.Manifest);
        signedBytes[^2] ^= 0x01;
        var tampered = envelope with { Manifest = Convert.ToBase64String(signedBytes) };
        var tamperedBytes = JsonSerializer.SerializeToUtf8Bytes(tampered, JsonOptions());

        var exception = Assert.Throws<UpdateVerificationException>(() =>
            new UpdateManifestVerifier().Verify(tamperedBytes, CreatePolicy(authority.PublicKey)));

        StringAssert.Contains(exception.Message, "signature");
    }

    [TestMethod]
    public void UnknownSigningKeyIsRejectedBeforeManifestFieldsAreTrusted()
    {
        using var authority = new TestAuthority();
        var package = Encoding.UTF8.GetBytes("synthetic package");
        var manifest = CreateManifest("0.1.0", 1, new Uri("https://packages.test.invalid/Witness-0.1.0-full.nupkg"), package);
        var envelopeBytes = authority.Sign(manifest, keyId: "untrusted-key");

        var exception = Assert.Throws<UpdateVerificationException>(() =>
            new UpdateManifestVerifier().Verify(envelopeBytes, CreatePolicy(authority.PublicKey)));

        StringAssert.Contains(exception.Message, "unknown key");
    }

    [TestMethod]
    public async Task TamperedPackageNeverReachesVelopackDestination()
    {
        using var authority = new TestAuthority();
        var expectedPackage = Encoding.UTF8.GetBytes("expected synthetic package");
        var servedPackage = Encoding.UTF8.GetBytes("tampered synthetic package");
        var packageUri = new Uri("https://packages.test.invalid/Witness-0.1.0-full.nupkg");
        var manifest = CreateManifest("0.1.0", 1, packageUri, expectedPackage);
        using var http = new HttpClient(new RouteHandler(new Dictionary<Uri, byte[]>
        {
            [ManifestUri] = authority.Sign(manifest),
            [packageUri] = servedPackage,
        }));
        using var source = new VerifiedManifestUpdateSource(CreatePolicy(authority.PublicKey), httpClient: http);
        var asset = (await source.GetReleaseFeed(null!, PackageId, "beta")).Assets.Single();
        var directory = Path.Combine(Path.GetTempPath(), "witness-update-tests", Guid.NewGuid().ToString("N"));
        var destination = Path.Combine(directory, asset.FileName);

        try
        {
            await Assert.ThrowsAsync<UpdateVerificationException>(() =>
                source.DownloadReleaseEntry(null!, asset, destination, _ => { }));
            Assert.IsFalse(File.Exists(destination));
            Assert.IsFalse(File.Exists(destination + ".partial"));
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [TestMethod]
    public void WrongChannelAndArchitectureAreRejected()
    {
        using var authority = new TestAuthority();
        var package = Encoding.UTF8.GetBytes("synthetic package");
        var manifest = CreateManifest("0.1.0", 1, new Uri("https://packages.test.invalid/Witness-0.1.0-full.nupkg"), package) with
        {
            Channel = "stable",
            Architecture = "arm64",
        };

        Assert.Throws<UpdateVerificationException>(() =>
            new UpdateManifestVerifier().Verify(authority.Sign(manifest), CreatePolicy(authority.PublicKey)));
    }

    private static UpdateManifest CreateManifest(string version, int build, Uri packageUri, byte[] package) => new()
    {
        Schema = 1,
        Platform = "windows",
        Architecture = "x64",
        Channel = "beta",
        PackageId = PackageId,
        Version = version,
        Build = build,
        ReleaseUrl = packageUri.AbsoluteUri,
        Size = package.LongLength,
        Sha256 = Convert.ToHexString(SHA256.HashData(package)).ToLowerInvariant(),
        MinimumOs = "10.0.26100.0",
        ProductMajor = 1,
        ReleaseNotes = $"Synthetic release {version} build {build}.",
    };

    private static UpdateTrustPolicy CreatePolicy(byte[] publicKey) => new(
        ManifestUri,
        PackageId,
        "windows",
        "x64",
        "beta",
        1,
        new Version(10, 0, 26100, 0),
        2L * 1024 * 1024 * 1024,
        new Dictionary<string, byte[]> { [KeyId] = publicKey },
        new[] { "packages.test.invalid" });

    private static JsonSerializerOptions JsonOptions() => new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private sealed class TestAuthority : IDisposable
    {
        private readonly Key _key = Key.Create(
            SignatureAlgorithm.Ed25519,
            new KeyCreationParameters { ExportPolicy = KeyExportPolicies.AllowPlaintextExport });

        public byte[] PublicKey => _key.PublicKey.Export(KeyBlobFormat.RawPublicKey);

        public byte[] Sign(UpdateManifest manifest, string keyId = KeyId)
        {
            var manifestBytes = JsonSerializer.SerializeToUtf8Bytes(manifest, JsonOptions());
            var signature = SignatureAlgorithm.Ed25519.Sign(_key, manifestBytes);
            var envelope = new SignedUpdateEnvelope
            {
                Schema = 1,
                KeyId = keyId,
                Manifest = Convert.ToBase64String(manifestBytes),
                Signature = Convert.ToBase64String(signature),
            };
            return JsonSerializer.SerializeToUtf8Bytes(envelope, JsonOptions());
        }

        public void Dispose() => _key.Dispose();
    }

    private sealed class RouteHandler(IReadOnlyDictionary<Uri, byte[]> routes) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (request.RequestUri is null || !routes.TryGetValue(request.RequestUri, out var content))
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound) { RequestMessage = request });
            }

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                RequestMessage = request,
                Content = new ByteArrayContent(content),
            });
        }
    }
}
