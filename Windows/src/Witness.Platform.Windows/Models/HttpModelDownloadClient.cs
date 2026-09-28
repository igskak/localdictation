using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using Witness.Core.Models;

namespace Witness.Platform.Windows.Models;

public sealed class HttpModelDownloadClient : IModelDownloadClient, IDisposable
{
    private const int MaximumRedirects = 5;
    private readonly HttpClient httpClient;
    private bool disposed;

    public HttpModelDownloadClient(HttpMessageHandler? handler = null)
    {
        handler ??= new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
        };
        httpClient = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = TimeSpan.FromMinutes(30),
        };
    }

    public async Task<Stream> OpenReadAsync(
        ModelArtifact artifact,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        ArgumentNullException.ThrowIfNull(artifact);
        ValidateAllowedUri(artifact.DownloadUri);

        var currentUri = artifact.DownloadUri;
        for (var redirects = 0; redirects <= MaximumRedirects; redirects++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, currentUri);
            request.Headers.UserAgent.Add(new ProductInfoHeaderValue(
                "Witness-Windows-Beta",
                Witness.Core.ProductMetadata.Version));
            var response = await httpClient
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);

            if (IsRedirect(response.StatusCode))
            {
                if (redirects == MaximumRedirects || response.Headers.Location is null)
                {
                    response.Dispose();
                    throw new IOException("The model host returned an invalid redirect chain.");
                }

                var redirected = response.Headers.Location.IsAbsoluteUri
                    ? response.Headers.Location
                    : new Uri(currentUri, response.Headers.Location);
                response.Dispose();
                ValidateAllowedUri(redirected);
                currentUri = redirected;
                continue;
            }

            if (!response.IsSuccessStatusCode)
            {
                var statusCode = response.StatusCode;
                response.Dispose();
                throw new IOException($"The model host returned HTTP {(int)statusCode}.");
            }

            if (response.Content.Headers.ContentLength is long contentLength
                && contentLength != artifact.SizeBytes)
            {
                response.Dispose();
                throw new IOException("The model host returned an unexpected content length.");
            }

            try
            {
                var stream = await response.Content
                    .ReadAsStreamAsync(cancellationToken)
                    .ConfigureAwait(false);
                return new ResponseOwnedStream(stream, response);
            }
            catch
            {
                response.Dispose();
                throw;
            }
        }

        throw new IOException("The model redirect limit was exceeded.");
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        httpClient.Dispose();
    }

    private static bool IsRedirect(HttpStatusCode statusCode) => statusCode is
        HttpStatusCode.MovedPermanently
        or HttpStatusCode.Found
        or HttpStatusCode.SeeOther
        or HttpStatusCode.TemporaryRedirect
        or HttpStatusCode.PermanentRedirect;

    private static void ValidateAllowedUri(Uri uri)
    {
        var host = uri.IdnHost;
        if (!uri.IsAbsoluteUri
            || uri.Scheme != Uri.UriSchemeHttps
            || !(string.Equals(host, "huggingface.co", StringComparison.OrdinalIgnoreCase)
                || host.EndsWith(".hf.co", StringComparison.OrdinalIgnoreCase)))
        {
            throw new IOException("The model download redirected outside its HTTPS host allowlist.");
        }
    }

    private sealed class ResponseOwnedStream(Stream inner, HttpResponseMessage response) : Stream
    {
        public override bool CanRead => inner.CanRead;
        public override bool CanSeek => inner.CanSeek;
        public override bool CanWrite => false;
        public override long Length => inner.Length;
        public override long Position
        {
            get => inner.Position;
            set => inner.Position = value;
        }

        public override void Flush() => inner.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
        public override int Read(Span<byte> buffer) => inner.Read(buffer);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
            inner.ReadAsync(buffer, cancellationToken);
        public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                inner.Dispose();
                response.Dispose();
            }
            base.Dispose(disposing);
        }

        public override async ValueTask DisposeAsync()
        {
            await inner.DisposeAsync().ConfigureAwait(false);
            response.Dispose();
            GC.SuppressFinalize(this);
        }
    }
}
