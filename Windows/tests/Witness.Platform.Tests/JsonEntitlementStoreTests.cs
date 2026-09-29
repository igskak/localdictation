using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Licensing;
using Witness.Platform.Windows.Licensing;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class JsonEntitlementStoreTests
{
    private static readonly DateTimeOffset Origin = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

    [TestMethod]
    public void RoundTripContainsExactlyTheFiveLicensingFields()
    {
        var files = new MemoryFileSystem();
        var store = new JsonEntitlementStore(@"C:\Witness\license.json", files);
        var record = new UsageRecord(
            Origin,
            "synthetic-install",
            Origin.AddMinutes(2),
            Origin.AddHours(3),
            "LD1.synthetic.fixture");

        store.Save(record);

        Assert.AreEqual(record, store.Load());
        var json = files.Files[@"C:\Witness\license.json"];
        using var parsed = JsonDocument.Parse(json);
        CollectionAssert.AreEquivalent(
            new[] { "installedAt", "installId", "firstDictationAt", "furthestSeenAt", "licenseToken" },
            parsed.RootElement.EnumerateObject().Select(property => property.Name).ToArray());
        Assert.DoesNotContain("transcript", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("glossary", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("history", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("audio", json, StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void MissingRecordIsAFirstRunRatherThanAnError()
    {
        var store = new JsonEntitlementStore(@"C:\Witness\license.json", new MemoryFileSystem());
        Assert.IsNull(store.Load());
    }

    [TestMethod]
    public void InvalidRecordFailsClosedInsteadOfSilentlyChangingEntitlement()
    {
        var files = new MemoryFileSystem();
        files.Files[@"C:\Witness\license.json"] = "{not-json";
        var store = new JsonEntitlementStore(@"C:\Witness\license.json", files);

        Assert.ThrowsExactly<EntitlementStoreException>(() => store.Load());
    }

    [TestMethod]
    public void SaveUsesReplacementAndRemovesTheTemporaryFile()
    {
        var files = new MemoryFileSystem();
        var store = new JsonEntitlementStore(@"C:\Witness\license.json", files);
        store.Save(UsageRecord.New(Origin, "synthetic-install"));

        Assert.IsTrue(files.Moves.Contains((@"C:\Witness\license.json.tmp", @"C:\Witness\license.json")));
        Assert.IsFalse(files.Files.ContainsKey(@"C:\Witness\license.json.tmp"));
    }

    private sealed class MemoryFileSystem : IEntitlementFileSystem
    {
        public Dictionary<string, string> Files { get; } = new(StringComparer.Ordinal);
        public List<(string Source, string Destination)> Moves { get; } = [];
        public bool Exists(string path) => Files.ContainsKey(path);
        public string ReadAllText(string path) => Files[path];
        public void WriteAllText(string path, string contents) => Files[path] = contents;
        public void MoveReplacing(string source, string destination)
        {
            Moves.Add((source, destination));
            Files[destination] = Files[source];
            Files.Remove(source);
        }
        public void DeleteIfExists(string path) => Files.Remove(path);
    }
}
