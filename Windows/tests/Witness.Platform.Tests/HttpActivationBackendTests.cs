using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Licensing;
using Witness.Platform.Windows.Licensing;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class HttpActivationBackendTests
{
    private static readonly Uri Endpoint = new("https://activation.example.invalid/v1/activate");
    private const string Device = "0123456789abcdef0123456789abcdef";
    private const string Email = "owner@example.invalid";
    private const string Key = "LD1.fixture.signature";

    [TestMethod]
    public void ActivationAndReleaseBodiesHaveOnlyTheirTwoAllowedFields()
    {
        using var activation = JsonDocument.Parse(HttpActivationBackend.ActivationBody(Email, Device));
        CollectionAssert.AreEquivalent(
            new[] { "device", "email" },
            activation.RootElement.EnumerateObject().Select(property => property.Name).ToArray());
        Assert.AreEqual(Device, activation.RootElement.GetProperty("device").GetString());
        Assert.AreEqual(Email, activation.RootElement.GetProperty("email").GetString());

        using var release = JsonDocument.Parse(HttpActivationBackend.ReleaseBody(Key, Device));
        CollectionAssert.AreEquivalent(
            new[] { "device", "key" },
            release.RootElement.EnumerateObject().Select(property => property.Name).ToArray());
        Assert.AreEqual(Device, release.RootElement.GetProperty("device").GetString());
        Assert.AreEqual(Key, release.RootElement.GetProperty("key").GetString());
    }

    [TestMethod]
    public async Task SuccessfulActivationReturnsOnlyAnLd1ShapedKey()
    {
        var transport = new FakeTransport(Response(200, new { key = Key }));
        var backend = new HttpActivationBackend(Endpoint, transport);

        var result = await backend.RequestKeyAsync(Email, Device);

        Assert.AreEqual(Key, result);
        Assert.AreEqual(Endpoint, transport.Requests.Single().Uri);
        Assert.AreEqual(HttpActivationBackend.MaximumResponseBytes, transport.MaximumResponseBytes);
    }

    [TestMethod]
    public async Task PlainHttpAndCrossOriginReleaseEndpointsFailBeforeTransport()
    {
        var transport = new FakeTransport(Response(200, new { key = Key }));
        var plain = new HttpActivationBackend(new Uri("http://activation.example.invalid/v1/activate"), transport);
        var crossOrigin = new HttpActivationBackend(
            Endpoint,
            transport,
            new Uri("https://other.example.invalid/v1/devices/release"));

        Assert.IsFalse(plain.IsConfigured);
        Assert.IsFalse(crossOrigin.IsConfigured);
        await Assert.ThrowsExactlyAsync<ActivationException>(() => plain.RequestKeyAsync(Email, Device));
        await Assert.ThrowsExactlyAsync<ActivationException>(() => crossOrigin.ReleaseDeviceAsync(Key, Device));
        Assert.IsEmpty(transport.Requests);
    }

    [TestMethod]
    public async Task InvalidDeviceIdentifierNeverReachesTransport()
    {
        var transport = new FakeTransport(Response(200, new { key = Key }));
        var backend = new HttpActivationBackend(Endpoint, transport);

        var error = await Assert.ThrowsExactlyAsync<ActivationException>(() =>
            backend.RequestKeyAsync(Email, "not-a-device"));

        Assert.AreEqual(ActivationErrorKind.Rejected, error.Kind);
        Assert.IsEmpty(transport.Requests);
    }

    [TestMethod]
    public async Task DeviceLimitAndTemporaryFailuresStayDistinct()
    {
        var limited = new HttpActivationBackend(Endpoint, new FakeTransport(Response(409, new { error = "device_limit" })));
        var busy = new HttpActivationBackend(Endpoint, new FakeTransport(Response(429, new { error = "rate_limited" })));

        var limitError = await Assert.ThrowsExactlyAsync<ActivationException>(() => limited.RequestKeyAsync(Email, Device));
        var busyError = await Assert.ThrowsExactlyAsync<ActivationException>(() => busy.RequestKeyAsync(Email, Device));

        Assert.AreEqual(ActivationErrorKind.DeviceLimitReached, limitError.Kind);
        Assert.AreEqual(ActivationErrorKind.Unreachable, busyError.Kind);
    }

    [TestMethod]
    public async Task UnknownHandIssuedKeyNeedsNoRemoteSlotRelease()
    {
        var transport = new FakeTransport(Response(404, new { error = "unknown_key" }));
        var backend = new HttpActivationBackend(Endpoint, transport);

        Assert.IsFalse(await backend.ReleaseDeviceAsync(Key, Device));
        Assert.AreEqual(new Uri("https://activation.example.invalid/v1/devices/release"), transport.Requests.Single().Uri);
    }

    [TestMethod]
    public async Task OversizedAndNonKeySuccessRepliesAreRejected()
    {
        var oversized = new HttpActivationBackend(
            Endpoint,
            new FakeTransport(new ActivationHttpResponse(200, new byte[HttpActivationBackend.MaximumResponseBytes + 1])));
        var html = new HttpActivationBackend(
            Endpoint,
            new FakeTransport(new ActivationHttpResponse(200, Encoding.UTF8.GetBytes("<html>not a key</html>"))));

        var sizeError = await Assert.ThrowsExactlyAsync<ActivationException>(() => oversized.RequestKeyAsync(Email, Device));
        var bodyError = await Assert.ThrowsExactlyAsync<ActivationException>(() => html.RequestKeyAsync(Email, Device));

        Assert.AreEqual(ActivationErrorKind.Rejected, sizeError.Kind);
        Assert.AreEqual(ActivationErrorKind.Rejected, bodyError.Kind);
    }

    [TestMethod]
    public async Task ServerMessageIsOneBoundedPrintableLine()
    {
        var message = new string('a', 250) + "\u0001\nsecond line";
        var backend = new HttpActivationBackend(
            Endpoint,
            new FakeTransport(Response(422, new { error = "future_code", message })));

        var error = await Assert.ThrowsExactlyAsync<ActivationException>(() => backend.RequestKeyAsync(Email, Device));

        Assert.AreEqual(ActivationErrorKind.Rejected, error.Kind);
        Assert.EndsWith("…", error.Message, StringComparison.Ordinal);
        Assert.IsLessThanOrEqualTo(HttpActivationBackend.MaximumServerMessageCharacters + 1, error.Message.Length);
        Assert.DoesNotContain("second line", error.Message, StringComparison.Ordinal);
        Assert.IsFalse(error.Message.Any(char.IsControl));
    }

    [TestMethod]
    public async Task ConcreteTransportSetsOnlyExpectedProductHeaders()
    {
        var handler = new CapturingHandler(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"key\":\"LD1.fixture.signature\"}", Encoding.UTF8, "application/json"),
        });
        using var transport = new HttpClientActivationTransport(handler);
        var backend = new HttpActivationBackend(Endpoint, transport);

        Assert.AreEqual(Key, await backend.RequestKeyAsync(Email, Device));

        Assert.AreEqual(HttpMethod.Post, handler.Method);
        Assert.AreEqual("Witness", handler.UserAgent);
        Assert.AreEqual("application/json", handler.Accept);
        Assert.AreEqual("application/json", handler.ContentType);
        Assert.IsFalse(handler.HasAuthorization);
        Assert.IsFalse(handler.HasCookie);
    }

    private static ActivationHttpResponse Response(int statusCode, object body) => new(
        statusCode,
        JsonSerializer.SerializeToUtf8Bytes(body));

    private sealed class FakeTransport(params ActivationHttpResponse[] responses) : IActivationHttpTransport
    {
        private readonly Queue<ActivationHttpResponse> responses = new(responses);
        public List<ActivationHttpRequest> Requests { get; } = [];
        public int MaximumResponseBytes { get; private set; }

        public Task<ActivationHttpResponse> PostJsonAsync(
            ActivationHttpRequest request,
            int maximumResponseBytes,
            CancellationToken cancellationToken)
        {
            Requests.Add(request);
            MaximumResponseBytes = maximumResponseBytes;
            return Task.FromResult(responses.Dequeue());
        }
    }

    private sealed class CapturingHandler(HttpResponseMessage response) : HttpMessageHandler
    {
        public HttpMethod? Method { get; private set; }
        public string? UserAgent { get; private set; }
        public string? Accept { get; private set; }
        public string? ContentType { get; private set; }
        public bool HasAuthorization { get; private set; }
        public bool HasCookie { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Method = request.Method;
            UserAgent = request.Headers.UserAgent.ToString();
            Accept = request.Headers.Accept.Single().MediaType;
            ContentType = request.Content?.Headers.ContentType?.MediaType;
            HasAuthorization = request.Headers.Authorization is not null;
            HasCookie = request.Headers.Contains("Cookie");
            return Task.FromResult(response);
        }
    }
}
