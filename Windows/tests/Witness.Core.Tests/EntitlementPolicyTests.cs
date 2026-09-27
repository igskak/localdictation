using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Licensing;
using Witness.Core.Recording;

namespace Witness.Core.Tests;

[TestClass]
public sealed class EntitlementPolicyTests
{
    private static readonly DateTimeOffset Origin = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

    [TestMethod]
    public void NothingIsAskedBeforeFirstNonEmptyDictation()
    {
        var state = EntitlementPolicy.Evaluate(Record(), null, Origin);
        Assert.AreEqual(EntitlementStateKind.Ungated, state.Kind);
        Assert.AreEqual(GraceStanding.Untouched, state.Grace);
        Assert.IsTrue(state.AllowsDictation);
    }

    [TestMethod]
    public void UngatedWindowIsThreeDaysFromFirstResultRegardlessOfCount()
    {
        Assert.AreEqual(TimeSpan.FromDays(3), EntitlementPolicy.UngatedDuration);
        foreach (var elapsed in new[] { TimeSpan.FromMinutes(1), TimeSpan.FromDays(1), TimeSpan.FromDays(3) - TimeSpan.FromSeconds(1) })
        {
            var state = EntitlementPolicy.Evaluate(Record(Origin), null, Origin + elapsed);
            Assert.AreEqual(EntitlementStateKind.Ungated, state.Kind);
            Assert.AreEqual(Origin + TimeSpan.FromDays(3), state.Grace?.ExpiresAt);
        }
    }

    [TestMethod]
    public void FourthDayRequiresActivationNotAnExpiredTrialMessage()
    {
        foreach (var elapsed in new[] { TimeSpan.FromDays(3), TimeSpan.FromDays(10), TimeSpan.FromDays(365) })
        {
            var state = EntitlementPolicy.Evaluate(Record(Origin, Origin + elapsed), null, Origin + elapsed);
            Assert.AreEqual(EntitlementLockKind.ActivationRequired, state.Lock?.Kind);
            Assert.IsFalse(state.WantsPurchase);
        }
    }

    [TestMethod]
    public void ActivatedTrialRunsTenDaysAndOutlivesUngatedWindow()
    {
        Assert.AreEqual(TimeSpan.FromDays(10), EntitlementPolicy.TrialDuration);
        var expiry = Origin + EntitlementPolicy.TrialDuration;
        var license = License(LicenseKind.Trial, expiry);
        var during = EntitlementPolicy.Evaluate(Record(Origin), license, Origin + TimeSpan.FromDays(4));
        Assert.AreEqual(EntitlementStateKind.Licensed, during.Kind);
        var ended = EntitlementPolicy.Evaluate(Record(Origin), license, expiry);
        Assert.AreEqual(EntitlementLockKind.ExpiredTrial, ended.Lock?.Kind);
    }

    [TestMethod]
    public void LifetimeNeverExpiresButCannotUnlockAnUnpurchasedMajor()
    {
        var license = License(LicenseKind.Lifetime, null);
        Assert.AreEqual(EntitlementStateKind.Licensed, EntitlementPolicy.Evaluate(Record(Origin), license, Origin + TimeSpan.FromDays(3650), "1.9.9").Kind);
        var newer = EntitlementPolicy.Evaluate(Record(Origin), license, Origin, "2.0.0");
        Assert.AreEqual(EntitlementLockKind.UpdateRequired, newer.Lock?.Kind);
        Assert.AreEqual(1, newer.Lock?.CoveredMajor);
        Assert.AreEqual(2, newer.Lock?.RunningMajor);
    }

    [TestMethod]
    public void AnnualLicenseExpiresOnItsDate()
    {
        var expiry = Origin + TimeSpan.FromDays(365);
        var state = EntitlementPolicy.Evaluate(Record(Origin), License(LicenseKind.Annual, expiry), expiry);
        Assert.AreEqual(EntitlementLockKind.ExpiredAnnual, state.Lock?.Kind);
        Assert.IsTrue(state.WantsPurchase);
    }

    [TestMethod]
    public void FurthestSeenTimePreventsClockRollback()
    {
        var record = Record(Origin).Observe(Origin + TimeSpan.FromDays(3) + TimeSpan.FromMinutes(1));
        var state = EntitlementPolicy.Evaluate(record, null, Origin + TimeSpan.FromHours(1));
        Assert.AreEqual(EntitlementLockKind.ActivationRequired, state.Lock?.Kind);
    }

    [TestMethod]
    public void MalformedVersionDefaultsToFirstMajor()
    {
        Assert.AreEqual(1, LifetimeUpdatePolicy.MajorOf(string.Empty));
        Assert.AreEqual(1, LifetimeUpdatePolicy.MajorOf("unknown"));
        Assert.AreEqual(0, LifetimeUpdatePolicy.MajorOf("0.1.0"));
        Assert.AreEqual(12, LifetimeUpdatePolicy.MajorOf("12.4"));
    }

    private static UsageRecord Record(DateTimeOffset? first = null, DateTimeOffset? furthest = null) =>
        new(Origin, "synthetic-install", first, furthest ?? Origin, null);

    private static License License(LicenseKind kind, DateTimeOffset? expiry) =>
        new("synthetic-license", "owner@example.invalid", kind, "0123456789abcdef0123456789abcdef", Origin, expiry);
}
