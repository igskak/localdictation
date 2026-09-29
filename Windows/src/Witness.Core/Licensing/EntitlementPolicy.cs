using Witness.Core.Recording;

namespace Witness.Core.Licensing;

public enum LicenseKind
{
    Trial,
    Annual,
    Lifetime,
}

public sealed record License(
    string Id,
    string Email,
    LicenseKind Kind,
    string DeviceId,
    DateTimeOffset IssuedAt,
    DateTimeOffset? ExpiresAt)
{
    public bool IsExpired(DateTimeOffset now) => ExpiresAt is DateTimeOffset expiry && now >= expiry;

    public int? DaysRemaining(DateTimeOffset now)
    {
        if (ExpiresAt is not DateTimeOffset expiry)
        {
            return null;
        }
        var seconds = (expiry - now).TotalSeconds;
        return seconds <= 0 ? 0 : (int)Math.Ceiling(seconds / 86_400);
    }
}

public sealed record UsageRecord(
    DateTimeOffset InstalledAt,
    string InstallId,
    DateTimeOffset? FirstDictationAt,
    DateTimeOffset FurthestSeenAt,
    string? LicenseToken)
{
    public static UsageRecord New(DateTimeOffset now, string installId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(installId);
        return new UsageRecord(now, installId, null, now, null);
    }

    public UsageRecord Observe(DateTimeOffset now) => now > FurthestSeenAt ? this with { FurthestSeenAt = now } : this;
    public DateTimeOffset EffectiveNow(DateTimeOffset now) => now > FurthestSeenAt ? now : FurthestSeenAt;
}

public enum EntitlementStateKind
{
    Ungated,
    Licensed,
    Locked,
}

public sealed record GraceStanding(DateTimeOffset? ExpiresAt)
{
    public static GraceStanding Untouched { get; } = new((DateTimeOffset?)null);
}

public sealed record EntitlementState(
    EntitlementStateKind Kind,
    GraceStanding? Grace = null,
    License? License = null,
    EntitlementLock? Lock = null)
{
    public bool AllowsDictation => Kind is EntitlementStateKind.Ungated or EntitlementStateKind.Licensed;

    public bool WantsPurchase => Kind switch
    {
        EntitlementStateKind.Locked when Lock?.Kind is EntitlementLockKind.ExpiredAnnual or EntitlementLockKind.UpdateRequired => true,
        EntitlementStateKind.Licensed when License?.Kind == LicenseKind.Trial => true,
        _ => false,
    };

    public static EntitlementState Ungated(GraceStanding grace) => new(EntitlementStateKind.Ungated, Grace: grace);
    public static EntitlementState Licensed(License license) => new(EntitlementStateKind.Licensed, License: license);
    public static EntitlementState Locked(EntitlementLock entitlementLock) => new(EntitlementStateKind.Locked, Lock: entitlementLock);
}

public static class EntitlementPolicy
{
    public static readonly TimeSpan UngatedDuration = TimeSpan.FromDays(3);
    public static readonly TimeSpan TrialDuration = TimeSpan.FromDays(10);

    public static EntitlementState Evaluate(
        UsageRecord record,
        License? license,
        DateTimeOffset now,
        string runningVersion = "1.0.0")
    {
        ArgumentNullException.ThrowIfNull(record);
        now = record.EffectiveNow(now);

        if (license is not null)
        {
            if (license.IsExpired(now))
            {
                var kind = license.Kind == LicenseKind.Trial ? EntitlementLockKind.ExpiredTrial : EntitlementLockKind.ExpiredAnnual;
                return EntitlementState.Locked(new EntitlementLock(kind, license.ExpiresAt ?? now));
            }
            var standing = LifetimeUpdatePolicy.StandingFor(license, runningVersion);
            if (standing.Kind == LifetimeStandingKind.Superseded)
            {
                return EntitlementState.Locked(new EntitlementLock(
                    EntitlementLockKind.UpdateRequired,
                    CoveredMajor: standing.CoveredMajor,
                    RunningMajor: standing.RunningMajor));
            }
            return EntitlementState.Licensed(license);
        }

        if (record.FirstDictationAt is not DateTimeOffset started)
        {
            return EntitlementState.Ungated(GraceStanding.Untouched);
        }
        var deadline = started + UngatedDuration;
        return now >= deadline
            ? EntitlementState.Locked(EntitlementLock.ActivationRequired)
            : EntitlementState.Ungated(new GraceStanding(deadline));
    }

    public static DateTimeOffset TrialExpiry(DateTimeOffset? firstDictationAt, DateTimeOffset now) =>
        (firstDictationAt ?? now) + TrialDuration;
}

public enum LifetimeStandingKind
{
    NotApplicable,
    Covered,
    Superseded,
}

public sealed record LifetimeStanding(LifetimeStandingKind Kind, int? CoveredMajor = null, int? RunningMajor = null);

public static class LifetimeUpdatePolicy
{
    public const int FirstMajor = 1;
    public static IReadOnlyList<(int Major, DateTimeOffset ReleasedAt)> LaterMajors { get; } = [];

    public static int CoveredMajor(DateTimeOffset issuedAt)
    {
        var covered = FirstMajor;
        foreach (var release in LaterMajors.Where(release => release.ReleasedAt <= issuedAt))
        {
            covered = Math.Max(covered, release.Major);
        }
        return covered;
    }

    public static int MajorOf(string version)
    {
        var first = version.Split('.', StringSplitOptions.None).FirstOrDefault();
        return int.TryParse(first, out var major) ? major : FirstMajor;
    }

    public static LifetimeStanding StandingFor(License license, string runningVersion)
    {
        if (license.Kind != LicenseKind.Lifetime)
        {
            return new(LifetimeStandingKind.NotApplicable);
        }
        var covered = CoveredMajor(license.IssuedAt);
        var running = MajorOf(runningVersion);
        return running > covered
            ? new(LifetimeStandingKind.Superseded, covered, running)
            : new(LifetimeStandingKind.Covered, covered);
    }

    public static string Promise(DateTimeOffset now) =>
        $"Paid once. Covers two computers, and version {CoveredMajor(now)} with every update to it.";
}
