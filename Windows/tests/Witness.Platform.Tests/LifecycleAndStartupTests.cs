using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Platform.Windows.Lifecycle;
using Witness.Platform.Windows.Startup;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class LifecycleAndStartupTests
{
    [TestMethod]
    public void NamedLeaseRejectsASecondProcessIdentity()
    {
        var id = $"Witness.Tests.{Guid.NewGuid():N}";
        using var first = SingleInstanceLease.TryAcquire(id);
        using var second = SingleInstanceLease.TryAcquire(id);
        Assert.IsTrue(first.IsPrimaryInstance);
        Assert.IsFalse(second.IsPrimaryInstance);
    }

    [TestMethod]
    public void StartupServiceWritesQuotedExecutableAndRemovesOnlyOwnedValue()
    {
        var store = new FakeStore();
        var service = new RunAtStartupService(store, "Witness", @"C:\Program Files\Witness\Witness.exe");
        service.SetEnabled(true);
        Assert.AreEqual("\"C:\\Program Files\\Witness\\Witness.exe\"", store.Value);
        Assert.IsTrue(service.IsEnabled);

        store.Value = "\"C:\\Other\\Witness.exe\"";
        service.SetEnabled(false);
        Assert.AreEqual("\"C:\\Other\\Witness.exe\"", store.Value);

        store.Value = "\"C:\\Program Files\\Witness\\Witness.exe\"";
        service.SetEnabled(false);
        Assert.IsNull(store.Value);
    }

    private sealed class FakeStore : IStartupValueStore
    {
        public string? Value { get; set; }
        public string? Read(string valueName) => Value;
        public void Write(string valueName, string value) => Value = value;
        public void Delete(string valueName) => Value = null;
    }
}
