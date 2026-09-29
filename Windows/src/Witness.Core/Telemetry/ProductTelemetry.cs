namespace Witness.Core.Telemetry;

public enum PaywallTrigger
{
    ActivationRequired,
    TrialExpired,
    LicenseExpired,
    UpdateRequired,
}

public sealed record ProductTelemetryEvent
{
    private ProductTelemetryEvent(string name, string? qualifier)
    {
        Name = name;
        Qualifier = qualifier;
    }

    public string Name { get; }
    public string? Qualifier { get; }

    public static ProductTelemetryEvent TrialStarted { get; } = new("trial_started", null);
    public static ProductTelemetryEvent ActivationRequested { get; } = new("activation_requested", null);
    public static ProductTelemetryEvent PaywallShown(PaywallTrigger trigger) => new(
        "paywall_shown",
        trigger switch
        {
            PaywallTrigger.ActivationRequired => "activationRequired",
            PaywallTrigger.TrialExpired => "trialExpired",
            PaywallTrigger.LicenseExpired => "licenseExpired",
            PaywallTrigger.UpdateRequired => "updateRequired",
            _ => throw new ArgumentOutOfRangeException(nameof(trigger)),
        });
}

public sealed record ProductTelemetryEnvelope(
    string Event,
    string? Qualifier,
    string AppVersion,
    string SystemVersion,
    string InstallId);

public interface IProductTelemetryService
{
    void Send(ProductTelemetryEvent telemetryEvent);
}

public sealed class LocalOnlyProductTelemetryService : IProductTelemetryService
{
    private readonly string appVersion;
    private readonly string systemVersion;
    private readonly string installId;

    public LocalOnlyProductTelemetryService(string appVersion, string systemVersion, string installId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(appVersion);
        ArgumentException.ThrowIfNullOrWhiteSpace(systemVersion);
        ArgumentException.ThrowIfNullOrWhiteSpace(installId);
        this.appVersion = appVersion;
        this.systemVersion = systemVersion;
        this.installId = installId;
    }

    public ProductTelemetryEnvelope EnvelopeFor(ProductTelemetryEvent telemetryEvent) => new(
        telemetryEvent.Name,
        telemetryEvent.Qualifier,
        appVersion,
        systemVersion,
        installId);

    public void Send(ProductTelemetryEvent telemetryEvent)
    {
        // The beta default deliberately performs no I/O and retains no queue.
        _ = EnvelopeFor(telemetryEvent);
    }
}

public sealed class TelemetryConsent
{
    private readonly object gate = new();
    private bool isAllowed;

    public TelemetryConsent(bool isAllowed = true)
    {
        this.isAllowed = isAllowed;
    }

    public bool IsAllowed
    {
        get
        {
            lock (gate) return isAllowed;
        }
        set
        {
            lock (gate) isAllowed = value;
        }
    }
}
