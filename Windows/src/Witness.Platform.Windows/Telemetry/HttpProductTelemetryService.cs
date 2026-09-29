using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using Witness.Core.Telemetry;

namespace Witness.Platform.Windows.Telemetry;

public sealed record ProductEventRequest(Uri Uri, byte[] Body);

public interface IProductEventTransport
{
    void Send(ProductEventRequest request);
}

public sealed class FireAndForgetProductEventTransport : IProductEventTransport, IDisposable
{
    private readonly HttpClient client;

    public FireAndForgetProductEventTransport(HttpMessageHandler? handler = null)
    {
        if (handler is null)
        {
            handler = new HttpClientHandler
            {
                AllowAutoRedirect = false,
                UseCookies = false,
            };
        }
        client = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = TimeSpan.FromSeconds(15),
        };
    }

    public void Send(ProductEventRequest request) => _ = SendOnceAsync(request);

    public void Dispose() => client.Dispose();

    private async Task SendOnceAsync(ProductEventRequest request)
    {
        try
        {
            using var message = new HttpRequestMessage(HttpMethod.Post, request.Uri)
            {
                Content = new ByteArrayContent(request.Body),
            };
            message.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            message.Headers.UserAgent.ParseAdd("Witness");
            using var response = await client.SendAsync(
                message,
                HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or ObjectDisposedException)
        {
            // Product events never affect dictation or licensing and are not retried.
        }
    }
}

public sealed class HttpProductTelemetryService : IProductTelemetryService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly Uri endpoint;
    private readonly LocalOnlyProductTelemetryService local;
    private readonly TelemetryConsent consent;
    private readonly IProductEventTransport transport;

    public HttpProductTelemetryService(
        Uri endpoint,
        LocalOnlyProductTelemetryService local,
        TelemetryConsent consent,
        IProductEventTransport transport)
    {
        this.endpoint = endpoint ?? throw new ArgumentNullException(nameof(endpoint));
        this.local = local ?? throw new ArgumentNullException(nameof(local));
        this.consent = consent ?? throw new ArgumentNullException(nameof(consent));
        this.transport = transport ?? throw new ArgumentNullException(nameof(transport));
    }

    public bool IsConfigured => endpoint.IsAbsoluteUri
        && string.Equals(endpoint.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);

    public void Send(ProductTelemetryEvent telemetryEvent)
    {
        var envelope = local.EnvelopeFor(telemetryEvent);
        if (!IsConfigured || !consent.IsAllowed)
        {
            local.Send(telemetryEvent);
            return;
        }

        transport.Send(new ProductEventRequest(endpoint, Serialize(envelope)));
    }

    internal static byte[] Serialize(ProductTelemetryEnvelope envelope) => JsonSerializer.SerializeToUtf8Bytes(
        new ProductEventBody(
            envelope.AppVersion,
            envelope.Event,
            envelope.InstallId,
            envelope.Qualifier,
            envelope.SystemVersion),
        JsonOptions);

    private sealed record ProductEventBody(
        [property: JsonPropertyName("app_version")] string AppVersion,
        [property: JsonPropertyName("event")] string Event,
        [property: JsonPropertyName("install_id")] string InstallId,
        [property: JsonPropertyName("qualifier")] string? Qualifier,
        [property: JsonPropertyName("system_version")] string SystemVersion);
}
