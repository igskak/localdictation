namespace Witness.Core.Licensing;

using Witness.Core.Telemetry;

public interface IEntitlementStore
{
    UsageRecord? Load();
    void Save(UsageRecord record);
}

/// <summary>
/// Owns the local licensing record and always re-derives entitlement from the
/// stored token, the injected clock and the current product version. Network
/// access exists only in the explicit activation/release methods; the normal
/// entitlement check is offline and never stores a decoded email separately.
/// </summary>
public sealed class EntitlementSession
{
    private readonly IEntitlementStore store;
    private readonly LicenseKeyVerifier verifier;
    private readonly LicenseAuthority authority;
    private readonly string? deviceId;
    private readonly string runningVersion;
    private readonly Func<DateTimeOffset> clock;
    private readonly IActivationBackend activationBackend;
    private readonly IProductTelemetryService telemetry;
    private UsageRecord record;

    public EntitlementSession(
        IEntitlementStore store,
        LicenseKeyVerifier verifier,
        LicenseAuthority authority,
        string? deviceId,
        string runningVersion,
        Func<DateTimeOffset>? clock = null,
        Func<string>? installIdFactory = null,
        IActivationBackend? activationBackend = null,
        IProductTelemetryService? telemetry = null)
    {
        this.store = store ?? throw new ArgumentNullException(nameof(store));
        this.verifier = verifier ?? throw new ArgumentNullException(nameof(verifier));
        this.authority = authority ?? throw new ArgumentNullException(nameof(authority));
        if (deviceId is not null && !DeviceIdentityDerivation.IsValidDeviceId(deviceId))
            throw new ArgumentException("A derived 32-character Windows device ID is required.", nameof(deviceId));
        ArgumentException.ThrowIfNullOrWhiteSpace(runningVersion);
        this.deviceId = deviceId;
        this.runningVersion = runningVersion;
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
        this.activationBackend = activationBackend ?? new UnconfiguredActivationBackend();
        installIdFactory ??= () => Guid.NewGuid().ToString("D");

        var loaded = store.Load();
        record = loaded ?? UsageRecord.New(this.clock(), installIdFactory());
        if (loaded is null)
        {
            store.Save(record);
        }
        this.telemetry = telemetry ?? new LocalOnlyProductTelemetryService(
            ProductMetadata.Version,
            "windows-local",
            record.InstallId);
        Reevaluate(discardInvalidStoredToken: true);
    }

    public EntitlementState State { get; private set; } = EntitlementState.Ungated(GraceStanding.Untouched);
    public License? License { get; private set; }
    public string InstallId => record.InstallId;
    public DateTimeOffset? FirstDictationAt => record.FirstDictationAt;
    public bool CanRequestActivation => deviceId is not null && authority.IsConfigured && activationBackend.IsConfigured;
    public bool CanEnterLicenseKey => deviceId is not null && authority.IsConfigured;
    public bool HasStoredLicenseToken => record.LicenseToken is not null;

    public EntitlementState Refresh()
    {
        var observed = record.Observe(clock());
        if (observed != record)
        {
            SaveReplacing(observed);
        }
        Reevaluate(discardInvalidStoredToken: true);
        return State;
    }

    public EntitlementState RecordSuccessfulDictation()
    {
        var now = clock();
        var updated = record.Observe(now);
        var isFirst = updated.FirstDictationAt is null;
        if (isFirst)
        {
            updated = updated with { FirstDictationAt = now };
        }
        SaveReplacing(updated);
        if (isFirst) telemetry.Send(ProductTelemetryEvent.TrialStarted);
        Reevaluate(discardInvalidStoredToken: true);
        return State;
    }

    public License AcceptLicense(string token)
    {
        if (deviceId is null)
        {
            throw new LicenseKeyVerificationException(
                LicenseKeyErrorKind.DeviceIdentityUnavailable,
                "Windows did not provide a usable hardware identity.");
        }
        var license = verifier.Verify(token, authority, deviceId);
        SaveReplacing(record with { LicenseToken = token.Trim() });
        Reevaluate(discardInvalidStoredToken: false);
        return license;
    }

    public async Task<License> RequestActivationAsync(
        string email,
        CancellationToken cancellationToken = default)
    {
        var address = email.Trim();
        if (!EmailAddress.LooksComplete(address))
        {
            throw new ActivationException(ActivationErrorKind.InvalidEmail, "The email address does not look complete.");
        }
        if (!activationBackend.IsConfigured)
        {
            throw new ActivationException(
                ActivationErrorKind.NotConfigured,
                "This build has no activation service. Paste a license key instead.");
        }
        if (!authority.IsConfigured)
        {
            throw new ActivationException(
                ActivationErrorKind.NotConfigured,
                "This build has no matching license authority and cannot safely request a key.");
        }
        if (deviceId is null)
        {
            throw new ActivationException(
                ActivationErrorKind.DeviceIdentityUnavailable,
                "Windows did not provide a usable hardware identity.");
        }

        telemetry.Send(ProductTelemetryEvent.ActivationRequested);
        var token = await activationBackend.RequestKeyAsync(address, deviceId, cancellationToken).ConfigureAwait(false);
        try
        {
            return AcceptLicense(token);
        }
        catch (LicenseKeyVerificationException exception)
        {
            throw new ActivationException(
                ActivationErrorKind.Rejected,
                "The activation service returned a key this build could not verify.",
                exception);
        }
    }

    public async Task<DeviceReleaseOutcome> ReleaseFromThisComputerAsync(
        CancellationToken cancellationToken = default)
    {
        var token = record.LicenseToken;
        if (token is null)
        {
            return new DeviceReleaseOutcome(DeviceReleaseOutcomeKind.RemovedLocally);
        }
        if (deviceId is null)
        {
            RemoveLicense();
            return new DeviceReleaseOutcome(
                DeviceReleaseOutcomeKind.RemovedLocallyOnly,
                "Windows did not provide a usable hardware identity, so the remote device slot could not be released.");
        }
        if (!activationBackend.IsConfigured)
        {
            RemoveLicense();
            return new DeviceReleaseOutcome(DeviceReleaseOutcomeKind.RemovedLocally);
        }

        DeviceReleaseOutcome outcome;
        try
        {
            var released = await activationBackend.ReleaseDeviceAsync(token, deviceId, cancellationToken).ConfigureAwait(false);
            outcome = new DeviceReleaseOutcome(
                released ? DeviceReleaseOutcomeKind.ReleasedEverywhere : DeviceReleaseOutcomeKind.RemovedLocally);
        }
        catch (ActivationException exception)
        {
            outcome = new DeviceReleaseOutcome(DeviceReleaseOutcomeKind.RemovedLocallyOnly, exception.Message);
        }
        catch (Exception)
        {
            outcome = new DeviceReleaseOutcome(
                DeviceReleaseOutcomeKind.RemovedLocallyOnly,
                "The remote device slot could not be released.");
        }

        RemoveLicense();
        return outcome;
    }

    public EntitlementState RemoveLicense()
    {
        if (record.LicenseToken is not null)
        {
            SaveReplacing(record with { LicenseToken = null });
        }
        Reevaluate(discardInvalidStoredToken: false);
        return State;
    }

    public void RecordPaywallShown(PaywallTrigger trigger) =>
        telemetry.Send(ProductTelemetryEvent.PaywallShown(trigger));

    private void Reevaluate(bool discardInvalidStoredToken)
    {
        License? verified = null;
        if (record.LicenseToken is string token && deviceId is not null)
        {
            try
            {
                verified = verifier.Verify(token, authority, deviceId);
            }
            catch (LicenseKeyVerificationException exception) when (
                discardInvalidStoredToken && exception.Kind is LicenseKeyErrorKind.NoAuthority)
            {
                // A build awaiting its beta authority cannot evaluate the key,
                // but must not destroy one a configured build can verify later.
            }
            catch (LicenseKeyVerificationException) when (discardInvalidStoredToken)
            {
                SaveReplacing(record with { LicenseToken = null });
            }
        }

        License = verified;
        State = EntitlementPolicy.Evaluate(record, verified, clock(), runningVersion);
    }

    private void SaveReplacing(UsageRecord replacement)
    {
        store.Save(replacement);
        record = replacement;
    }
}
