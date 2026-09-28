using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Models;
using Witness.Platform.Windows.Models;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class HttpModelDownloadClientTests
{
    [TestMethod]
    public async Task AllowedRedirectReturnsExpectedPayloadWithoutCookies()
    {
        var bytes = "model-payload"u8.ToArray();
        var requests = new List<HttpRequestMessage>();
        var handler = new DelegateHandler(request =>
        {
            requests.Add(CloneRequest(request));
            if (request.RequestUri!.Host == "huggingface.co")
            {
                return new HttpResponseMessage(HttpStatusCode.Found)
                {
                    Headers = { Location = new Uri("https://us.aws.cdn.hf.co/model.bin") },
                };
            }

            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(bytes),
            };
        });
        using var client = new HttpModelDownloadClient(handler);

        await using var stream = await client.OpenReadAsync(ArtifactFor(bytes), CancellationToken.None);
        using var destination = new MemoryStream();
        await stream.CopyToAsync(destination);

        CollectionAssert.AreEqual(bytes, destination.ToArray());
        Assert.HasCount(2, requests);
        Assert.IsTrue(requests.All(request => request.Headers.UserAgent.ToString() == "Witness-Windows-Beta/0.1.0"));
        Assert.IsTrue(requests.All(request => !request.Headers.Contains("Cookie")));
    }

    [TestMethod]
    public async Task RedirectOutsideAllowlistIsRejectedBeforeRequest()
    {
        var calls = 0;
        var handler = new DelegateHandler(_ =>
        {
            calls++;
            return new HttpResponseMessage(HttpStatusCode.Found)
            {
                Headers = { Location = new Uri("https://example.invalid/model.bin") },
            };
        });
        using var client = new HttpModelDownloadClient(handler);

        await Assert.ThrowsAsync<IOException>(async () =>
        {
            await using var ignored = await client.OpenReadAsync(
                ArtifactFor("model"u8.ToArray()),
                CancellationToken.None);
        });
        Assert.AreEqual(1, calls);
    }

    [TestMethod]
    public async Task UnexpectedContentLengthIsRejected()
    {
        var bytes = "short"u8.ToArray();
        var artifact = ArtifactFor("expected-length"u8.ToArray());
        var handler = new DelegateHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent(bytes),
        });
        using var client = new HttpModelDownloadClient(handler);

        await Assert.ThrowsAsync<IOException>(async () =>
        {
            await using var ignored = await client.OpenReadAsync(artifact, CancellationToken.None);
        });
    }

    private static ModelArtifact ArtifactFor(byte[] bytes) => new(
        Id: "test",
        Revision: new string('a', 40),
        FileName: "model.bin",
        DownloadUri: new Uri("https://huggingface.co/test/model.bin"),
        SizeBytes: bytes.Length,
        Sha256: Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
        License: "test-only");

    private static HttpRequestMessage CloneRequest(HttpRequestMessage request)
    {
        var clone = new HttpRequestMessage(request.Method, request.RequestUri);
        foreach (var header in request.Headers)
        {
            clone.Headers.TryAddWithoutValidation(header.Key, header.Value);
        }
        return clone;
    }

    private sealed class DelegateHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => Task.FromResult(responder(request));
    }
}
