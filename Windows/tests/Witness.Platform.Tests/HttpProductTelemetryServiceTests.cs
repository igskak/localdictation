using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Telemetry;
using Witness.Platform.Windows.Telemetry;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class HttpProductTelemetryServiceTests
{
    private static readonly Uri Endpoint = new("https://events.example.invalid/v1/events");

    [TestMethod]
    public void WireBodyHasOnlyTheFiveDisclosedFields()
    {
        var local = new LocalOnlyProductTelemetryService("0.1.0", "windows-10.0", "11111111-1111-4111-8111-111111111111");
        var body = HttpProductTelemetryService.Serialize(
            local.EnvelopeFor(ProductTelemetryEvent.PaywallShown(PaywallTrigger.TrialExpired)));

        using var document = JsonDocument.Parse(body);
        CollectionAssert.AreEquivalent(
            new[] { "app_version", "event", "install_id", "qualifier", "system_version" },
            document.RootElement.EnumerateObject().Select(property => property.Name).ToArray());
        Assert.AreEqual("paywall_shown", document.RootElement.GetProperty("event").GetString());
        Assert.AreEqual("trialExpired", document.RootElement.GetProperty("qualifier").GetString());
        Assert.AreEqual("windows-10.0", document.RootElement.GetProperty("system_version").GetString());
    }

    [TestMethod]
    public void EventWithoutQualifierOmitsTheField()
    {
        var local = new LocalOnlyProductTelemetryService("0.1.0", "windows-10.0", "11111111-1111-4111-8111-111111111111");
        using var document = JsonDocument.Parse(HttpProductTelemetryService.Serialize(
            local.EnvelopeFor(ProductTelemetryEvent.TrialStarted)));

        Assert.IsFalse(document.RootElement.TryGetProperty("qualifier", out _));
    }

    [TestMethod]
    public void ConsentAndHttpsAreBothRequiredAtSendTime()
    {
        var consent = new TelemetryConsent();
        var local = new LocalOnlyProductTelemetryService("0.1.0", "windows-10.0", "11111111-1111-4111-8111-111111111111");
        var sent = new CapturingTransport();
        var service = new HttpProductTelemetryService(Endpoint, local, consent, sent);

        service.Send(ProductTelemetryEvent.TrialStarted);
        consent.IsAllowed = false;
        service.Send(ProductTelemetryEvent.ActivationRequested);

        Assert.HasCount(1, sent.Requests);
        Assert.AreEqual(Endpoint, sent.Requests[0].Uri);

        var insecureSent = new CapturingTransport();
        var insecure = new HttpProductTelemetryService(
            new Uri("http://events.example.invalid/v1/events"),
            local,
            new TelemetryConsent(),
            insecureSent);
        insecure.Send(ProductTelemetryEvent.TrialStarted);
        Assert.IsEmpty(insecureSent.Requests);
    }

    private sealed class CapturingTransport : IProductEventTransport
    {
        public List<ProductEventRequest> Requests { get; } = [];
        public void Send(ProductEventRequest request) => Requests.Add(request);
    }
}
