using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Insertion;
using Witness.Platform.Windows.Insertion;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class UiAutomationProtectionInspectorTests
{
    private static readonly InsertionTarget Target = new(42, 10);

    [TestMethod]
    public async Task KnownProbeResultsArePreserved()
    {
        using var ordinary = new UiAutomationProtectionInspector(
            new FixedProbe(new(InsertionProtectionState.Ordinary)));
        using var protectedField = new UiAutomationProtectionInspector(
            new FixedProbe(new(InsertionProtectionState.Protected)));

        Assert.AreEqual(
            InsertionProtectionState.Ordinary,
            await ordinary.InspectAsync(Target, TimeSpan.FromSeconds(1)));
        Assert.AreEqual(
            InsertionProtectionState.Protected,
            await protectedField.InspectAsync(Target, TimeSpan.FromSeconds(1)));
    }

    [TestMethod]
    public async Task FieldObservationVerifiesOnlyExactSelectionReplacement()
    {
        var before = new UiAutomationFieldObservation(
            InsertionProtectionState.Ordinary,
            "draft old",
            SelectionStart: 6,
            SelectionLength: 3);
        using var inspector = new UiAutomationProtectionInspector(new FixedProbe(before));

        var observed = await inspector.ObserveAsync(Target, TimeSpan.FromSeconds(1));

        Assert.AreEqual("draft new words", observed.ExpectedAfterPaste("new words"));
        Assert.IsTrue(observed.VerifiesPaste(
            new UiAutomationFieldObservation(InsertionProtectionState.Ordinary, "draft new words"),
            "new words"));
        Assert.IsFalse(observed.VerifiesPaste(
            new UiAutomationFieldObservation(InsertionProtectionState.Ordinary, "different"),
            "new words"));
        Assert.IsFalse(observed.VerifiesPaste(
            new UiAutomationFieldObservation(InsertionProtectionState.Protected, "draft new words"),
            "new words"));
    }

    [TestMethod]
    public async Task ProbeExceptionFailsClosed()
    {
        using var inspector = new UiAutomationProtectionInspector(new ThrowingProbe());

        Assert.AreEqual(
            InsertionProtectionState.Unknown,
            await inspector.InspectAsync(Target, TimeSpan.FromSeconds(1)));
    }

    [TestMethod]
    public async Task HungProviderTimesOutAndDoesNotCreateUnboundedWorkers()
    {
        using var release = new ManualResetEventSlim(false);
        var probe = new BlockingProbe(release);
        using var inspector = new UiAutomationProtectionInspector(probe);
        try
        {
            var first = inspector.InspectAsync(Target, TimeSpan.FromMilliseconds(250));
            Assert.IsTrue(probe.Entered.Wait(TimeSpan.FromSeconds(1)));
            Assert.AreEqual(
                InsertionProtectionState.Unknown,
                await first);
            Assert.AreEqual(
                InsertionProtectionState.Unknown,
                await inspector.InspectAsync(Target, TimeSpan.FromMilliseconds(50)));
            Assert.AreEqual(1, probe.Calls);
        }
        finally
        {
            release.Set();
        }
    }

    [TestMethod]
    public async Task CancellationIsNotConvertedIntoAnAllowedOrUnknownResult()
    {
        using var release = new ManualResetEventSlim(false);
        using var inspector = new UiAutomationProtectionInspector(new BlockingProbe(release));
        using var cancellation = new CancellationTokenSource();
        try
        {
            cancellation.Cancel();
            await Assert.ThrowsAsync<OperationCanceledException>(() =>
                inspector.InspectAsync(Target, TimeSpan.FromSeconds(1), cancellation.Token));
        }
        finally
        {
            release.Set();
        }
    }

    private sealed class FixedProbe(UiAutomationFieldObservation result) : IUiAutomationProtectionProbe
    {
        public UiAutomationFieldObservation Inspect(InsertionTarget target) => result;
    }

    private sealed class ThrowingProbe : IUiAutomationProtectionProbe
    {
        public UiAutomationFieldObservation Inspect(InsertionTarget target) =>
            throw new InvalidOperationException("synthetic provider failure");
    }

    private sealed class BlockingProbe(ManualResetEventSlim release) : IUiAutomationProtectionProbe
    {
        private int calls;
        public int Calls => Volatile.Read(ref calls);
        public ManualResetEventSlim Entered { get; } = new(false);

        public UiAutomationFieldObservation Inspect(InsertionTarget target)
        {
            Interlocked.Increment(ref calls);
            Entered.Set();
            release.Wait();
            return new(InsertionProtectionState.Ordinary);
        }
    }
}
