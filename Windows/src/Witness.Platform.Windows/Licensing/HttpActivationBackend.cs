using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Witness.Core.Licensing;

namespace Witness.Platform.Windows.Licensing;

public sealed record ActivationHttpRequest(Uri Uri, byte[] Body);
public sealed record ActivationHttpResponse(int StatusCode, byte[] Body);

public interface IActivationHttpTransport
{
    Task<ActivationHttpResponse> PostJsonAsync(
        ActivationHttpRequest request,
        int maximumResponseBytes,
        CancellationToken cancellationToken);
}

public sealed class HttpClientActivationTransport : IActivationHttpTransport, IDisposable
{
    private readonly HttpClient client;

    public HttpClientActivationTransport(HttpMessageHandler? handler = null)
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
            Timeout = TimeSpan.FromSeconds(30),
        };
    }

    public async Task<ActivationHttpResponse> PostJsonAsync(
        ActivationHttpRequest request,
        int maximumResponseBytes,
        CancellationToken cancellationToken)
    {
        using var message = new HttpRequestMessage(HttpMethod.Post, request.Uri)
        {
            Content = new ByteArrayContent(request.Body),
        };
        message.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        message.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        message.Headers.UserAgent.ParseAdd("Witness");
        using var response = await client.SendAsync(
            message,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        var body = await ReadBoundedAsync(response.Content, maximumResponseBytes, cancellationToken).ConfigureAwait(false);
        return new ActivationHttpResponse((int)response.StatusCode, body);
    }

    public void Dispose() => client.Dispose();

    private static async Task<byte[]> ReadBoundedAsync(
        HttpContent content,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is long length && length > maximumBytes)
            throw new ActivationException(ActivationErrorKind.Rejected, "The activation response is too large.");

        await using var stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream(Math.Min(maximumBytes, 1024));
        var buffer = new byte[1024];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            if (output.Length + read > maximumBytes)
                throw new ActivationException(ActivationErrorKind.Rejected, "The activation response is too large.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }
}

/// <summary>
/// The only production-compatible activation network boundary. Callers supply
/// a compiled endpoint and invoke it only after an explicit user action. The
/// request shapes are fixed and contain no extension dictionary for content.
/// </summary>
public sealed class HttpActivationBackend : IActivationBackend
{
    public const int MaximumResponseBytes = 8 * 1024;
    public const int MaximumLicenseCharacters = 4096;
    public const int MaximumServerMessageCharacters = 200;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    };

    private readonly Uri activationEndpoint;
    private readonly Uri releaseEndpoint;
    private readonly IActivationHttpTransport transport;

    public HttpActivationBackend(
        Uri activationEndpoint,
        IActivationHttpTransport transport,
        Uri? releaseEndpoint = null)
    {
        this.activationEndpoint = activationEndpoint ?? throw new ArgumentNullException(nameof(activationEndpoint));
        this.transport = transport ?? throw new ArgumentNullException(nameof(transport));
        this.releaseEndpoint = releaseEndpoint ?? SiblingRelease(activationEndpoint);
    }

    public bool IsConfigured => IsHttps(activationEndpoint)
        && IsHttps(releaseEndpoint)
        && string.Equals(activationEndpoint.Host, releaseEndpoint.Host, StringComparison.OrdinalIgnoreCase)
        && activationEndpoint.Port == releaseEndpoint.Port;

    public async Task<string> RequestKeyAsync(
        string email,
        string deviceId,
        CancellationToken cancellationToken = default)
    {
        if (!IsConfigured) throw NotConfigured();
        var address = email.Trim();
        if (!EmailAddress.LooksComplete(address))
            throw new ActivationException(ActivationErrorKind.InvalidEmail, "The email address does not look complete.");
        if (!DeviceIdentityDerivation.IsValidDeviceId(deviceId))
            throw new ActivationException(ActivationErrorKind.Rejected, "The Windows device identifier is invalid.");

        var body = Serialize(new ActivationRequest(deviceId, address));
        var response = await SendAsync(activationEndpoint, body, cancellationToken).ConfigureAwait(false);
        var reply = ParseReply(response.Body);
        if (response.StatusCode is >= 200 and <= 299)
        {
            var key = reply?.Key?.Trim();
            if (string.IsNullOrEmpty(key)
                || !key.StartsWith(LicenseKeyVerifier.Prefix + ".", StringComparison.Ordinal)
                || key.Length > MaximumLicenseCharacters)
            {
                throw new ActivationException(ActivationErrorKind.Rejected, "The activation service replied without a valid key.");
            }
            return key;
        }
        throw MapError(response.StatusCode, reply);
    }

    public async Task<bool> ReleaseDeviceAsync(
        string key,
        string deviceId,
        CancellationToken cancellationToken = default)
    {
        if (!IsConfigured) throw NotConfigured();
        if (!DeviceIdentityDerivation.IsValidDeviceId(deviceId))
            throw new ActivationException(ActivationErrorKind.Rejected, "The Windows device identifier is invalid.");
        var response = await SendAsync(
            releaseEndpoint,
            Serialize(new ReleaseRequest(deviceId, key.Trim())),
            cancellationToken).ConfigureAwait(false);
        var reply = ParseReply(response.Body);
        if (response.StatusCode is >= 200 and <= 299) return true;
        if (response.StatusCode == 404 && string.Equals(reply?.Error, "unknown_key", StringComparison.Ordinal)) return false;
        throw MapError(response.StatusCode, reply);
    }

    public static Uri SiblingRelease(Uri activationEndpoint)
    {
        ArgumentNullException.ThrowIfNull(activationEndpoint);
        var root = new Uri(activationEndpoint, ".");
        return new Uri(root, "devices/release");
    }

    internal static byte[] ActivationBody(string email, string deviceId) => Serialize(new ActivationRequest(deviceId, email));
    internal static byte[] ReleaseBody(string key, string deviceId) => Serialize(new ReleaseRequest(deviceId, key));

    private async Task<ActivationHttpResponse> SendAsync(Uri endpoint, byte[] body, CancellationToken cancellationToken)
    {
        try
        {
            var response = await transport.PostJsonAsync(
                new ActivationHttpRequest(endpoint, body),
                MaximumResponseBytes,
                cancellationToken).ConfigureAwait(false);
            if (response.Body.Length > MaximumResponseBytes)
                throw new ActivationException(ActivationErrorKind.Rejected, "The activation response is too large.");
            return response;
        }
        catch (ActivationException)
        {
            throw;
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or TaskCanceledException)
        {
            throw new ActivationException(ActivationErrorKind.Unreachable, "The activation service could not be reached.", exception);
        }
    }

    private static ActivationReply? ParseReply(byte[] body)
    {
        try
        {
            return JsonSerializer.Deserialize<ActivationReply>(body, JsonOptions);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static ActivationException MapError(int statusCode, ActivationReply? reply)
    {
        if (statusCode == 429 || statusCode is >= 500 and <= 599)
            return new ActivationException(ActivationErrorKind.Unreachable, "The activation service is temporarily unavailable.");
        return reply?.Error switch
        {
            "invalid_email" => new ActivationException(ActivationErrorKind.InvalidEmail, "The email address was refused."),
            "device_limit" => new ActivationException(ActivationErrorKind.DeviceLimitReached, "This license already covers two computers."),
            "invalid_device" => new ActivationException(ActivationErrorKind.Rejected, "This build sent an invalid device identifier."),
            "trial_used" => new ActivationException(ActivationErrorKind.Rejected, Sanitize(reply.Message) ?? "The free trial has already been used."),
            "invalid_request" => new ActivationException(ActivationErrorKind.Rejected, "The request was incomplete."),
            "bad_key" => new ActivationException(ActivationErrorKind.Rejected, "The license key did not verify."),
            "device_mismatch" => new ActivationException(ActivationErrorKind.Rejected, "The key belongs to a different computer."),
            "unknown_key" => new ActivationException(ActivationErrorKind.Rejected, "The activation service has no record of that key."),
            _ => new ActivationException(
                ActivationErrorKind.Rejected,
                Sanitize(reply?.Message) ?? $"The activation service refused the request ({statusCode})."),
        };
    }

    private static string? Sanitize(string? value)
    {
        if (value is null) return null;
        var firstLine = value.Split(['\r', '\n'], 2, StringSplitOptions.None)[0];
        var printable = new string(firstLine.Where(character => !char.IsControl(character)).ToArray()).Trim();
        if (printable.Length == 0) return null;
        return printable.Length <= MaximumServerMessageCharacters
            ? printable
            : string.Concat(printable.AsSpan(0, MaximumServerMessageCharacters).TrimEnd(), "…");
    }

    private static bool IsHttps(Uri endpoint) => endpoint.IsAbsoluteUri
        && string.Equals(endpoint.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);

    private static byte[] Serialize<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);

    private static ActivationException NotConfigured() => new(
        ActivationErrorKind.NotConfigured,
        "This build has no valid HTTPS activation service.");

    private sealed record ActivationRequest(
        [property: JsonPropertyName("device")] string Device,
        [property: JsonPropertyName("email")] string Email);

    private sealed record ReleaseRequest(
        [property: JsonPropertyName("device")] string Device,
        [property: JsonPropertyName("key")] string Key);

    private sealed record ActivationReply(
        [property: JsonPropertyName("key")] string? Key,
        [property: JsonPropertyName("error")] string? Error,
        [property: JsonPropertyName("message")] string? Message);
}
