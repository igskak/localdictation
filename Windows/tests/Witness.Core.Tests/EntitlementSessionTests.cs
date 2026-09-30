using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Licensing;
using Witness.Core.Telemetry;

namespace Witness.Core.Tests;

[TestClass]
public sealed class EntitlementSessionTests
{
    private static readonly DateTimeOffset Origin = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

    [TestMethod]
    public void FirstLaunchPersistsAnUntouchedLocalRecord()
    {
        var store = new MemoryStore();
        var session = CreateSession(store, Origin);

        Assert.AreEqual(EntitlementStateKind.Ungated, session.State.Kind);
        Assert.AreEqual(GraceStanding.Untouched, session.State.Grace);
        Assert.AreEqual("synthetic-install", session.InstallId);
        Assert.IsNull(session.FirstDictationAt);
        Assert.AreEqual(1, store.SaveCount);
    }

    [TestMethod]
    public void OnlyTheFirstSuccessfulDictationStartsTheThreeDayWindow()
    {
        var now = Origin;
        var store = new MemoryStore();
        var session = CreateSession(store, () => now);

        session.RecordSuccessfulDictation();
        now = Origin.AddDays(1);
        session.RecordSuccessfulDictation();

        Assert.AreEqual(Origin, session.FirstDictationAt);
        Assert.AreEqual(Origin.AddDays(3), session.State.Grace?.ExpiresAt);
    }

    [TestMethod]
    public void AcceptedServiceKeySurvivesRestartAndWorksOffline()
    {
        var fixture = LoadFixture();
        var store = new MemoryStore();
        var session = CreateSession(store, Origin, fixture);
        var trial = fixture.Keys.Single(key => key.Kind == "trial");

        var accepted = session.AcceptLicense(trial.Token);
        var restarted = CreateSession(store, Origin.AddDays(1), fixture);

        Assert.AreEqual(LicenseKind.Trial, accepted.Kind);
        Assert.AreEqual(EntitlementStateKind.Licensed, restarted.State.Kind);
        Assert.AreEqual(trial.Id, restarted.License?.Id);
        Assert.AreEqual(trial.Token, store.Record?.LicenseToken);
    }

    [TestMethod]
    public void RejectedKeyDoesNotReplaceTheStoredLicense()
    {
        var fixture = LoadFixture();
        var store = new MemoryStore();
        var session = CreateSession(store, Origin, fixture);
        var lifetime = fixture.Keys.Single(key => key.Kind == "lifetime");
        session.AcceptLicense(lifetime.Token);

        Assert.ThrowsExactly<LicenseKeyVerificationException>(() => session.AcceptLicense("LD1.invalid.signature"));

        Assert.AreEqual(lifetime.Token, store.Record?.LicenseToken);
        Assert.AreEqual(LicenseKind.Lifetime, session.License?.Kind);
    }

    [TestMethod]
    public void InvalidStoredTokenIsDiscardedOnRestart()
    {
        var fixture = LoadFixture();
        var store = new MemoryStore
        {
            Record = UsageRecord.New(Origin, "synthetic-install") with { LicenseToken = "LD1.invalid.signature" },
        };

        var restarted = CreateSession(store, Origin, fixture);

        Assert.IsNull(restarted.License);
        Assert.IsNull(store.Record?.LicenseToken);
        Assert.AreEqual(EntitlementStateKind.Ungated, restarted.State.Kind);
    }

    [TestMethod]
    public void TemporarilyUnconfiguredBuildDoesNotDestroyAStoredKey()
    {
        var fixture = LoadFixture();
        var token = fixture.Keys.Single(key => key.Kind == "lifetime").Token;
        var store = new MemoryStore
        {
            Record = UsageRecord.New(Origin, "synthetic-install") with { LicenseToken = token },
        };

        _ = new EntitlementSession(
            store,
            new LicenseKeyVerifier(),
            LicenseAuthority.Unconfigured,
            fixture.Device,
            "1.0.0",
            () => Origin,
            () => "synthetic-install");

        Assert.AreEqual(token, store.Record?.LicenseToken);
    }

    [TestMethod]
    public async Task MissingHardwareIdentityPreservesStoredKeyButCanStillRemoveItLocally()
    {
        var fixture = LoadFixture();
        var token = fixture.Keys.Single(key => key.Kind == "lifetime").Token;
        var store = new MemoryStore
        {
            Record = UsageRecord.New(Origin, "synthetic-install") with { LicenseToken = token },
        };
        var session = new EntitlementSession(
            store,
            new LicenseKeyVerifier(),
            LicenseAuthority.FromBase64(fixture.PublicKeyBase64),
            deviceId: null,
            "1.0.0",
            () => Origin,
            () => "synthetic-install",
            new FakeActivationBackend { Key = token });

        Assert.IsFalse(session.CanRequestActivation);
        Assert.IsFalse(session.CanEnterLicenseKey);
        Assert.IsTrue(session.HasStoredLicenseToken);
        Assert.IsNull(session.License);
        Assert.AreEqual(token, store.Record?.LicenseToken);
        var error = Assert.ThrowsExactly<LicenseKeyVerificationException>(() => session.AcceptLicense(token));
        Assert.AreEqual(LicenseKeyErrorKind.DeviceIdentityUnavailable, error.Kind);

        var outcome = await session.ReleaseFromThisComputerAsync();

        Assert.AreEqual(DeviceReleaseOutcomeKind.RemovedLocallyOnly, outcome.Kind);
        Assert.IsFalse(session.HasStoredLicenseToken);
        Assert.IsNull(store.Record?.LicenseToken);
    }

    [TestMethod]
    public async Task MissingAuthorityPreventsActivationBeforeTheBackendIsCalled()
    {
        var fixture = LoadFixture();
        var backend = new FakeActivationBackend { Key = fixture.Keys[0].Token };
        var session = new EntitlementSession(
            new MemoryStore(),
            new LicenseKeyVerifier(),
            LicenseAuthority.Unconfigured,
            fixture.Device,
            "1.0.0",
            () => Origin,
            () => "synthetic-install",
            backend);

        Assert.IsFalse(session.CanRequestActivation);
        var error = await Assert.ThrowsExactlyAsync<ActivationException>(() =>
            session.RequestActivationAsync(EmailForTest));

        Assert.AreEqual(ActivationErrorKind.NotConfigured, error.Kind);
        Assert.IsNull(backend.Email);
    }

    [TestMethod]
    public void FailedPersistenceDoesNotClaimThatAKeyWasAccepted()
    {
        var fixture = LoadFixture();
        var store = new MemoryStore();
        var session = CreateSession(store, Origin, fixture);
        var before = store.Record;
        store.FailSaves = true;

        Assert.ThrowsExactly<InvalidOperationException>(() => session.AcceptLicense(fixture.Keys[0].Token));

        Assert.AreEqual(before, store.Record);
        Assert.IsNull(session.License);
        Assert.AreEqual(EntitlementStateKind.Ungated, session.State.Kind);
    }

    [TestMethod]
    public async Task ExplicitActivationStoresOnlyAKeyThatVerifiesLocally()
    {
        var fixture = LoadFixture();
        var backend = new FakeActivationBackend
        {
            Key = fixture.Keys.Single(key => key.Kind == "lifetime").Token,
        };
        var store = new MemoryStore();
        var session = CreateSession(store, Origin, fixture, backend);

        var license = await session.RequestActivationAsync("  owner@example.invalid  ");

        Assert.AreEqual(LicenseKind.Lifetime, license.Kind);
        Assert.AreEqual("owner@example.invalid", backend.Email);
        Assert.AreEqual(fixture.Device, backend.DeviceId);
        Assert.AreEqual(backend.Key, store.Record?.LicenseToken);
    }

    [TestMethod]
    public async Task InvalidEmailNeverReachesTheActivationBackend()
    {
        var backend = new FakeActivationBackend { Key = "unused" };
        var session = CreateSession(new MemoryStore(), Origin, backend: backend);

        var error = await Assert.ThrowsExactlyAsync<ActivationException>(() => session.RequestActivationAsync("not-an-address"));

        Assert.AreEqual(ActivationErrorKind.InvalidEmail, error.Kind);
        Assert.IsNull(backend.Email);
    }

    [TestMethod]
    public async Task ReleaseFreesRemoteSlotBeforeRemovingTheLocalKey()
    {
        var fixture = LoadFixture();
        var backend = new FakeActivationBackend
        {
            Key = fixture.Keys.Single(key => key.Kind == "lifetime").Token,
            ReleaseResult = true,
        };
        var store = new MemoryStore();
        var session = CreateSession(store, Origin, fixture, backend);
        session.AcceptLicense(backend.Key);

        var outcome = await session.ReleaseFromThisComputerAsync();

        Assert.AreEqual(DeviceReleaseOutcomeKind.ReleasedEverywhere, outcome.Kind);
        Assert.AreEqual(backend.Key, backend.ReleasedKey);
        Assert.IsNull(store.Record?.LicenseToken);
        Assert.IsNull(session.License);
    }

    [TestMethod]
    public async Task FailedRemoteReleaseStillRemovesTheLocalKeyAndWarns()
    {
        var fixture = LoadFixture();
        var backend = new FakeActivationBackend
        {
            Key = fixture.Keys.Single(key => key.Kind == "lifetime").Token,
            ReleaseError = new ActivationException(ActivationErrorKind.Unreachable, "Synthetic service outage."),
        };
        var store = new MemoryStore();
        var session = CreateSession(store, Origin, fixture, backend);
        session.AcceptLicense(backend.Key);

        var outcome = await session.ReleaseFromThisComputerAsync();

        Assert.AreEqual(DeviceReleaseOutcomeKind.RemovedLocallyOnly, outcome.Kind);
        Assert.AreEqual("Synthetic service outage.", outcome.Warning);
        Assert.IsNull(store.Record?.LicenseToken);
    }

    [TestMethod]
    public async Task SessionEmitsOnlyFirstResultAndExplicitActivationFacts()
    {
        var fixture = LoadFixture();
        var backend = new FakeActivationBackend
        {
            Key = fixture.Keys.Single(key => key.Kind == "lifetime").Token,
        };
        var telemetry = new CapturingTelemetry();
        var session = CreateSession(new MemoryStore(), Origin, fixture, backend, telemetry);

        session.RecordSuccessfulDictation();
        session.RecordSuccessfulDictation();
        await session.RequestActivationAsync(EmailForTest);

        CollectionAssert.AreEqual(
            new[] { "trial_started", "activation_requested" },
            telemetry.Events.Select(item => item.Name).ToArray());
    }

    private static EntitlementSession CreateSession(
        MemoryStore store,
        DateTimeOffset now,
        ParityFixture? fixture = null,
        IActivationBackend? backend = null,
        IProductTelemetryService? telemetry = null) =>
        CreateSession(store, () => now, fixture, backend, telemetry);

    private static EntitlementSession CreateSession(
        MemoryStore store,
        Func<DateTimeOffset> clock,
        ParityFixture? fixture = null,
        IActivationBackend? backend = null,
        IProductTelemetryService? telemetry = null)
    {
        fixture ??= LoadFixture();
        return new EntitlementSession(
            store,
            new LicenseKeyVerifier(),
            LicenseAuthority.FromBase64(fixture.PublicKeyBase64),
            fixture.Device,
            "1.0.0",
            clock,
            () => "synthetic-install",
            backend,
            telemetry);
    }

    private static ParityFixture LoadFixture()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "activation-service-parity.json");
        return JsonSerializer.Deserialize<ParityFixture>(File.ReadAllBytes(path), new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        }) ?? throw new InvalidOperationException("The activation service parity fixture is empty.");
    }

    private sealed class MemoryStore : IEntitlementStore
    {
        public UsageRecord? Record { get; set; }
        public int SaveCount { get; private set; }
        public bool FailSaves { get; set; }
        public UsageRecord? Load() => Record;
        public void Save(UsageRecord record)
        {
            if (FailSaves) throw new InvalidOperationException("Synthetic write failure.");
            Record = record;
            SaveCount++;
        }
    }

    private sealed class FakeActivationBackend : IActivationBackend
    {
        public bool IsConfigured { get; init; } = true;
        public required string Key { get; init; }
        public bool ReleaseResult { get; init; }
        public ActivationException? ReleaseError { get; init; }
        public string? Email { get; private set; }
        public string? DeviceId { get; private set; }
        public string? ReleasedKey { get; private set; }

        public Task<string> RequestKeyAsync(string email, string deviceId, CancellationToken cancellationToken = default)
        {
            Email = email;
            DeviceId = deviceId;
            return Task.FromResult(Key);
        }

        public Task<bool> ReleaseDeviceAsync(string key, string deviceId, CancellationToken cancellationToken = default)
        {
            ReleasedKey = key;
            DeviceId = deviceId;
            return ReleaseError is null
                ? Task.FromResult(ReleaseResult)
                : Task.FromException<bool>(ReleaseError);
        }
    }

    private sealed class CapturingTelemetry : IProductTelemetryService
    {
        public List<ProductTelemetryEvent> Events { get; } = [];
        public void Send(ProductTelemetryEvent telemetryEvent) => Events.Add(telemetryEvent);
    }

    private const string EmailForTest = "owner@example.invalid";

    private sealed record ParityFixture(string Device, string Email, string PublicKeyBase64, ParityKey[] Keys);
    private sealed record ParityKey(string Kind, string Id, long Issued, long? Expires, string Token);
}
