using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Telemetry;

namespace Witness.Core.Tests;

[TestClass]
public sealed class ProductTelemetryTests
{
    [TestMethod]
    public void OnlyTheThreeDisclosedEventsCanBeConstructed()
    {
        var events = new[]
        {
            ProductTelemetryEvent.TrialStarted,
            ProductTelemetryEvent.ActivationRequested,
            ProductTelemetryEvent.PaywallShown(PaywallTrigger.ActivationRequired),
            ProductTelemetryEvent.PaywallShown(PaywallTrigger.TrialExpired),
            ProductTelemetryEvent.PaywallShown(PaywallTrigger.LicenseExpired),
            ProductTelemetryEvent.PaywallShown(PaywallTrigger.UpdateRequired),
        };

        CollectionAssert.AreEquivalent(
            new[] { "trial_started", "activation_requested", "paywall_shown" },
            events.Select(item => item.Name).Distinct().ToArray());
        CollectionAssert.AreEquivalent(
            new[] { "activationRequired", "trialExpired", "licenseExpired", "updateRequired" },
            events.Select(item => item.Qualifier).OfType<string>().ToArray());
    }

    [TestMethod]
    public void LocalOnlyServiceBuildsTheFiveFieldEnvelopeWithoutIo()
    {
        var service = new LocalOnlyProductTelemetryService("0.1.0", "windows-10.0", "synthetic-install");
        var envelope = service.EnvelopeFor(ProductTelemetryEvent.PaywallShown(PaywallTrigger.TrialExpired));

        Assert.AreEqual("paywall_shown", envelope.Event);
        Assert.AreEqual("trialExpired", envelope.Qualifier);
        Assert.AreEqual("0.1.0", envelope.AppVersion);
        Assert.AreEqual("windows-10.0", envelope.SystemVersion);
        Assert.AreEqual("synthetic-install", envelope.InstallId);
        service.Send(ProductTelemetryEvent.TrialStarted);
    }

    [TestMethod]
    public void ConsentDefaultsOnAndChangesImmediately()
    {
        var consent = new TelemetryConsent();
        Assert.IsTrue(consent.IsAllowed);
        consent.IsAllowed = false;
        Assert.IsFalse(consent.IsAllowed);
    }
}
