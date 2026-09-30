using System.Buffers;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using Velopack;
using Velopack.Logging;
using Velopack.Sources;

namespace Witness.Update;

public sealed class VerifiedManifestUpdateSource : IUpdateSource, IDisposable
{
    private const int CopyBufferBytes = 64 * 1024;
    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;
    private readonly UpdateTrustPolicy _policy;
    private readonly UpdateManifestVerifier _verifier;
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private VerifiedUpdateManifest? _verified;
    private string? _downloadedPackagePath;
    private VelopackAsset? _downloadedAsset;

    public VerifiedManifestUpdateSource(
        UpdateTrustPolicy policy,
        UpdateManifestVerifier? verifier = null,
        HttpClient? httpClient = null)
    {
        _policy = policy ?? throw new ArgumentNullException(nameof(policy));
        _verifier = verifier ?? new UpdateManifestVerifier();
        _httpClient = httpClient ?? CreateHttpClient();
        _ownsHttpClient = httpClient is null;
    }

    public VerifiedUpdateManifest? VerifiedManifest => Volatile.Read(ref _verified);

    public async Task<VelopackAssetFeed> GetReleaseFeed(
        IVelopackLogger logger,
        string? appId,
        string channel,
        Guid? stagingId = null,
        VelopackAsset? latestLocalRelease = null)
    {
        _ = logger;
        _ = stagingId;
        _ = latestLocalRelease;

        if (appId is not null && !string.Equals(appId, _policy.PackageId, StringComparison.Ordinal))
        {
            throw new UpdateVerificationException("Velopack requested a feed for a different package ID.");
        }

        if (!string.Equals(channel, _policy.Channel, StringComparison.Ordinal))
        {
            throw new UpdateVerificationException("Velopack requested a different update channel.");
        }

        await _operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            using var response = await SendFollowingAllowedRedirectsAsync(
                _policy.ManifestUri,
                uri => uri == _policy.ManifestUri,
                acceptJson: true,
                CancellationToken.None).ConfigureAwait(false);
            EnsureSuccessfulAllowedResponse(response, uri => uri == _policy.ManifestUri, "manifest");
            var envelope = await ReadLimitedAsync(response.Content, 128 * 1024, CancellationToken.None).ConfigureAwait(false);
            _verified = _verifier.Verify(envelope, _policy);
            var manifest = _verified.Manifest;

            return new VelopackAssetFeed
            {
                Assets =
                [
                    new VelopackAsset
                    {
                        PackageId = manifest.PackageId,
                        Version = SemanticVersion.Parse(manifest.Version),
                        Type = VelopackAssetType.Full,
                        FileName = Path.GetFileName(_verified.PackageUri.AbsolutePath),
                        SHA1 = string.Empty,
                        SHA256 = manifest.Sha256,
                        Size = manifest.Size,
                        NotesMarkdown = manifest.ReleaseNotes,
                        NotesHTML = string.Empty,
                    },
                ],
            };
        }
        finally
        {
            _operationGate.Release();
        }
    }

    public async Task DownloadReleaseEntry(
        IVelopackLogger logger,
        VelopackAsset releaseEntry,
        string localFile,
        Action<int> progress,
        CancellationToken cancelToken = default)
    {
        _ = logger;
        ArgumentNullException.ThrowIfNull(releaseEntry);
        ArgumentException.ThrowIfNullOrWhiteSpace(localFile);
        ArgumentNullException.ThrowIfNull(progress);

        await _operationGate.WaitAsync(cancelToken).ConfigureAwait(false);
        var partialFile = localFile + ".partial";
        try
        {
            var verified = _verified ?? throw new UpdateVerificationException("The update feed must be verified before download.");
            EnsureAssetMatches(releaseEntry, verified.Manifest);

            using var response = await SendFollowingAllowedRedirectsAsync(
                verified.PackageUri,
                _policy.IsAllowedPackageUri,
                acceptJson: false,
                cancelToken).ConfigureAwait(false);
            EnsureSuccessfulAllowedResponse(response, _policy.IsAllowedPackageUri, "package");

            if (response.Content.Headers.ContentLength is long contentLength && contentLength != verified.Manifest.Size)
            {
                throw new UpdateVerificationException("The update package length does not match its signed manifest.");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(localFile))!);
            await using var input = await response.Content.ReadAsStreamAsync(cancelToken).ConfigureAwait(false);
            await using var output = new FileStream(
                partialFile,
                FileMode.Create,
                FileAccess.Write,
                FileShare.None,
                CopyBufferBytes,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = ArrayPool<byte>.Shared.Rent(CopyBufferBytes);
            long total = 0;
            try
            {
                while (true)
                {
                    var read = await input.ReadAsync(buffer.AsMemory(0, buffer.Length), cancelToken).ConfigureAwait(false);
                    if (read == 0)
                    {
                        break;
                    }

                    total += read;
                    if (total > verified.Manifest.Size)
                    {
                        throw new UpdateVerificationException("The update package is larger than its signed manifest.");
                    }

                    hash.AppendData(buffer, 0, read);
                    await output.WriteAsync(buffer.AsMemory(0, read), cancelToken).ConfigureAwait(false);
                    progress((int)Math.Min(99, total * 100 / verified.Manifest.Size));
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
            }

            await output.FlushAsync(cancelToken).ConfigureAwait(false);
            RequirePackage(total, Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant(), verified.Manifest);
            output.Close();
            File.Move(partialFile, localFile, overwrite: true);
            _downloadedPackagePath = Path.GetFullPath(localFile);
            _downloadedAsset = releaseEntry;
            progress(100);
        }
        catch
        {
            TryDelete(partialFile);
            throw;
        }
        finally
        {
            _operationGate.Release();
        }
    }

    public async Task ReverifyDownloadedPackageAsync(
        VelopackAsset releaseEntry,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(releaseEntry);
        await _operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var downloadedPath = _downloadedPackagePath
                ?? throw new UpdateVerificationException("No verified update package has been downloaded.");
            var downloadedAsset = _downloadedAsset
                ?? throw new UpdateVerificationException("No verified update asset has been retained.");
            if (!AssetsMatch(releaseEntry, downloadedAsset))
                throw new UpdateVerificationException("The package selected for apply is not the downloaded verified asset.");

            using var response = await SendFollowingAllowedRedirectsAsync(
                _policy.ManifestUri,
                uri => uri == _policy.ManifestUri,
                acceptJson: true,
                cancellationToken).ConfigureAwait(false);
            EnsureSuccessfulAllowedResponse(response, uri => uri == _policy.ManifestUri, "manifest");
            var envelope = await ReadLimitedAsync(response.Content, 128 * 1024, cancellationToken).ConfigureAwait(false);
            var latest = _verifier.Verify(envelope, _policy);
            EnsureSameManifest(_verified, latest);
            EnsureAssetMatches(releaseEntry, latest.Manifest);

            var file = new FileInfo(downloadedPath);
            if (!file.Exists || file.Length != latest.Manifest.Size)
                throw new UpdateVerificationException("The downloaded package no longer matches its signed size.");
            await using var input = new FileStream(
                downloadedPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                CopyBufferBytes,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = ArrayPool<byte>.Shared.Rent(CopyBufferBytes);
            try
            {
                while (true)
                {
                    var read = await input.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken).ConfigureAwait(false);
                    if (read == 0) break;
                    hash.AppendData(buffer, 0, read);
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
            }
            RequirePackage(file.Length, Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant(), latest.Manifest);
            _verified = latest;
        }
        finally
        {
            _operationGate.Release();
        }
    }

    public void Dispose()
    {
        _operationGate.Dispose();
        if (_ownsHttpClient)
        {
            _httpClient.Dispose();
        }
    }

    private static HttpClient CreateHttpClient()
    {
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.All,
        };
        return new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(15) };
    }

    private static HttpRequestMessage CreateRequest(Uri uri, bool acceptJson)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("Witness", "0.1.0"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(
            acceptJson ? "application/json" : "application/octet-stream"));
        return request;
    }

    private async Task<HttpResponseMessage> SendFollowingAllowedRedirectsAsync(
        Uri initialUri,
        Func<Uri, bool> isAllowed,
        bool acceptJson,
        CancellationToken cancellationToken)
    {
        var current = initialUri;
        for (var redirects = 0; redirects <= 3; redirects++)
        {
            if (!isAllowed(current))
                throw new UpdateVerificationException("An update redirect URL is not allowed.");
            using var request = CreateRequest(current, acceptJson);
            var response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (!IsRedirect(response.StatusCode)) return response;
            var location = response.Headers.Location;
            response.Dispose();
            if (location is null)
                throw new UpdateVerificationException("An update redirect did not include a location.");
            current = location.IsAbsoluteUri ? location : new Uri(current, location);
        }
        throw new UpdateVerificationException("The update request exceeded the redirect limit.");
    }

    private static void EnsureSuccessfulAllowedResponse(HttpResponseMessage response, Func<Uri, bool> isAllowed, string kind)
    {
        response.EnsureSuccessStatusCode();
        var finalUri = response.RequestMessage?.RequestUri;
        if (finalUri is null || !isAllowed(finalUri))
        {
            throw new UpdateVerificationException($"The final {kind} URL is not allowed.");
        }
    }

    private static async Task<byte[]> ReadLimitedAsync(HttpContent content, int maximumBytes, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is long length && length > maximumBytes)
        {
            throw new UpdateVerificationException("The update envelope is too large.");
        }

        await using var stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var memory = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return memory.ToArray();
            }

            if (memory.Length + read > maximumBytes)
            {
                throw new UpdateVerificationException("The update envelope is too large.");
            }

            await memory.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
        }
    }

    private static void EnsureAssetMatches(VelopackAsset asset, UpdateManifest manifest)
    {
        var matches = asset.Type == VelopackAssetType.Full
            && string.Equals(asset.PackageId, manifest.PackageId, StringComparison.Ordinal)
            && string.Equals(asset.Version.ToNormalizedString(), SemanticVersion.Parse(manifest.Version).ToNormalizedString(), StringComparison.Ordinal)
            && string.Equals(asset.SHA256, manifest.Sha256, StringComparison.Ordinal)
            && asset.Size == manifest.Size;
        if (!matches)
        {
            throw new UpdateVerificationException("Velopack requested an asset that does not match the verified manifest.");
        }
    }

    private static bool AssetsMatch(VelopackAsset left, VelopackAsset right) =>
        left.Type == right.Type
        && string.Equals(left.PackageId, right.PackageId, StringComparison.Ordinal)
        && string.Equals(left.Version.ToNormalizedString(), right.Version.ToNormalizedString(), StringComparison.Ordinal)
        && string.Equals(left.SHA256, right.SHA256, StringComparison.Ordinal)
        && left.Size == right.Size
        && string.Equals(left.FileName, right.FileName, StringComparison.Ordinal);

    private static bool IsRedirect(HttpStatusCode status) => status is
        HttpStatusCode.MovedPermanently
        or HttpStatusCode.Redirect
        or HttpStatusCode.RedirectMethod
        or HttpStatusCode.TemporaryRedirect
        or HttpStatusCode.PermanentRedirect;

    private static void RequirePackage(long size, string sha256, UpdateManifest manifest)
    {
        if (size != manifest.Size || !string.Equals(sha256, manifest.Sha256, StringComparison.Ordinal))
        {
            throw new UpdateVerificationException("The downloaded package does not match its signed size and SHA-256.");
        }
    }

    private static void EnsureSameManifest(VerifiedUpdateManifest? expected, VerifiedUpdateManifest actual)
    {
        if (expected is null
            || !CryptographicOperations.FixedTimeEquals(expected.SignedManifestBytes, actual.SignedManifestBytes)
            || !string.Equals(expected.KeyId, actual.KeyId, StringComparison.Ordinal))
            throw new UpdateVerificationException("The signed update manifest changed after download.");
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
