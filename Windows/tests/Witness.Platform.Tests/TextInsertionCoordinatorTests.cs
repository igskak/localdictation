using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Input;
using Witness.Core.Insertion;
using Witness.Platform.Windows.Insertion;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class TextInsertionCoordinatorTests
{
    private static readonly InsertionTarget Captured = new(42, 10);
    private static readonly ForegroundTargetObservation SameTarget = new(true, Captured);
    private static readonly UiAutomationFieldObservation Ordinary =
        new(InsertionProtectionState.Ordinary, "draft old", 6, 3);

    [TestMethod]
    public async Task ProtectedAndUnknownFieldsHaveNoContentSideEffects()
    {
        foreach (var protection in new[]
        {
            InsertionProtectionState.Protected,
            InsertionProtectionState.Unknown,
        })
        {
            var fixture = new Fixture(new UiAutomationFieldObservation(protection));
            var result = await fixture.Coordinator.InsertAsync(
                "dictation",
                Captured,
                HotkeyModifiers.Control,
                () => true);

            Assert.AreEqual(
                protection == InsertionProtectionState.Protected
                    ? TextInsertionOutcomeKind.RefusedProtectedField
                    : TextInsertionOutcomeKind.RetainedInWitness,
                result.Kind);
            Assert.AreEqual(0, fixture.Clipboard.WriteCalls);
            Assert.AreEqual(0, fixture.Paste.PasteCalls);
            Assert.AreEqual(0, fixture.Direct.InsertCalls);
        }
    }

    [TestMethod]
    public async Task ChangedTargetGetsProtectedClipboardOnlyAfterProtectionCheck()
    {
        var changed = new InsertionTarget(42, 11);
        var fixture = new Fixture(Ordinary)
        {
            Targets = { Observation = new(true, changed) },
        };

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.CopiedForRecovery, result.Kind);
        Assert.AreEqual(InsertionPlanReason.TargetChanged, result.Reason);
        Assert.AreEqual(1, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(0, fixture.Paste.PasteCalls);
    }

    [TestMethod]
    public async Task ChangedTargetProtectionRaceFailsClosedBeforeClipboardWrite()
    {
        var changed = new InsertionTarget(42, 11);
        var fixture = new Fixture(
            Ordinary,
            new UiAutomationFieldObservation(InsertionProtectionState.Protected))
        {
            Targets = { Observation = new(true, changed) },
        };

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.RefusedProtectedField, result.Kind);
        Assert.AreEqual(0, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(0, fixture.Paste.PasteCalls);
    }

    [TestMethod]
    public async Task VerifiedDirectWriteNeverTouchesClipboard()
    {
        var fixture = new Fixture(Ordinary);
        fixture.Direct.Supports = true;
        fixture.Direct.Result = DirectTextInsertionResult.Verified;

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.InsertedDirect, result.Kind);
        Assert.AreEqual(1, fixture.Direct.InsertCalls);
        Assert.AreEqual(0, fixture.Clipboard.WriteCalls);
    }

    [TestMethod]
    public async Task UnverifiedDirectWriteIsNeverFollowedByPaste()
    {
        var fixture = new Fixture(Ordinary);
        fixture.Direct.Supports = true;
        fixture.Direct.Result = DirectTextInsertionResult.UnverifiedAfterWrite;

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.UnverifiedDirectWrite, result.Kind);
        Assert.AreEqual(0, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(0, fixture.Paste.PasteCalls);
    }

    [TestMethod]
    public async Task ExactPasteRestoresSnapshotOnlyAfterOnePaste()
    {
        var fixture = new Fixture(
            Ordinary,
            Ordinary,
            Ordinary,
            new UiAutomationFieldObservation(InsertionProtectionState.Ordinary, "draft dictation"));

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.InsertedByPaste, result.Kind);
        Assert.IsTrue(result.ClipboardRestored);
        Assert.AreEqual(1, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(1, fixture.Clipboard.RestoreCalls);
        Assert.AreEqual(1, fixture.Paste.PasteCalls);
    }

    [TestMethod]
    public async Task UnverifiedPasteLeavesDictationClipboardForRecovery()
    {
        var fixture = new Fixture(
            Ordinary,
            Ordinary,
            Ordinary,
            new UiAutomationFieldObservation(InsertionProtectionState.Ordinary, "unchanged"));

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.UnverifiedPaste, result.Kind);
        Assert.AreEqual(1, fixture.Paste.PasteCalls);
        Assert.AreEqual(0, fixture.Clipboard.RestoreCalls);
    }

    [TestMethod]
    public async Task TargetChangeDuringModifierWaitPreventsClipboardAndPaste()
    {
        var fixture = new Fixture(Ordinary);
        fixture.Paste.AfterWait = () => fixture.Targets.Observation =
            new ForegroundTargetObservation(true, new InsertionTarget(42, 11));

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.RetainedInWitness, result.Kind);
        Assert.AreEqual(0, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(0, fixture.Paste.PasteCalls);
    }

    [TestMethod]
    public async Task ModifierTimeoutPreventsClipboardWrite()
    {
        var fixture = new Fixture(Ordinary);
        fixture.Paste.ModifiersReleased = false;

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.RetainedInWitness, result.Kind);
        Assert.AreEqual(InsertionPlanReason.PasteUnavailable, result.Reason);
        Assert.AreEqual(0, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(0, fixture.Paste.PasteCalls);
    }

    [TestMethod]
    public async Task ProtectionChangeDuringModifierWaitPreventsClipboardWrite()
    {
        var fixture = new Fixture(
            Ordinary,
            new UiAutomationFieldObservation(InsertionProtectionState.Protected));

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.RefusedProtectedField, result.Kind);
        Assert.AreEqual(0, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(0, fixture.Paste.PasteCalls);
    }

    [TestMethod]
    public async Task SupersededGenerationDuringModifierWaitHasNoSideEffect()
    {
        var current = true;
        var fixture = new Fixture(Ordinary);
        fixture.Paste.AfterWait = () => current = false;

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => current);

        Assert.AreEqual(TextInsertionOutcomeKind.Cancelled, result.Kind);
        Assert.AreEqual(0, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(0, fixture.Paste.PasteCalls);
    }

    [TestMethod]
    public async Task ProtectionChangeAfterClipboardWritePreventsPasteAndKeepsRecoveryCopy()
    {
        var fixture = new Fixture(
            Ordinary,
            Ordinary,
            new UiAutomationFieldObservation(InsertionProtectionState.Protected));

        var result = await fixture.Coordinator.InsertAsync(
            "dictation",
            Captured,
            HotkeyModifiers.Control,
            () => true);

        Assert.AreEqual(TextInsertionOutcomeKind.CopiedForRecovery, result.Kind);
        Assert.AreEqual(InsertionPlanReason.ProtectedField, result.Reason);
        Assert.AreEqual(1, fixture.Clipboard.WriteCalls);
        Assert.AreEqual(0, fixture.Paste.PasteCalls);
        Assert.AreEqual(0, fixture.Clipboard.RestoreCalls);
    }

    private sealed class Fixture
    {
        public Fixture(params UiAutomationFieldObservation[] observations)
        {
            Fields = new FakeFields(observations);
            Coordinator = new(
                Targets,
                Fields,
                Direct,
                Clipboard,
                Paste,
                new NoDelay());
        }

        public FakeTargets Targets { get; } = new() { Observation = SameTarget };
        public FakeFields Fields { get; }
        public FakeDirect Direct { get; } = new();
        public FakeClipboard Clipboard { get; } = new();
        public FakePaste Paste { get; } = new();
        public TextInsertionCoordinator Coordinator { get; }
    }

    private sealed class FakeTargets : IInsertionTargetObserver
    {
        public ForegroundTargetObservation Observation { get; set; } = SameTarget;
        public ForegroundTargetObservation Observe() => Observation;
    }

    private sealed class FakeFields(params UiAutomationFieldObservation[] observations)
        : IInsertionFieldInspector
    {
        private readonly Queue<UiAutomationFieldObservation> remaining = new(observations);
        private UiAutomationFieldObservation? last;

        public Task<UiAutomationFieldObservation> ObserveAsync(
            InsertionTarget target,
            TimeSpan timeout,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            last = remaining.Count > 0 ? remaining.Dequeue() : last ?? UiAutomationFieldObservation.Unknown;
            return Task.FromResult(last);
        }

        public void Dispose()
        {
        }
    }

    private sealed class FakeDirect : IDirectTextInserter
    {
        public bool Supports { get; set; }
        public DirectTextInsertionResult Result { get; set; } = DirectTextInsertionResult.Unsupported;
        public int InsertCalls { get; private set; }

        public bool SupportsVerifiedSelectionReplacement(InsertionTarget target) => Supports;

        public DirectTextInsertionResult TryInsert(InsertionTarget target, string text)
        {
            InsertCalls++;
            return Result;
        }
    }

    private sealed class FakeClipboard : IProtectedClipboard
    {
        public int WriteCalls { get; private set; }
        public int RestoreCalls { get; private set; }
        public bool WriteSucceeds { get; set; } = true;
        public ClipboardSnapshotRestoreResult RestoreResult { get; set; } =
            ClipboardSnapshotRestoreResult.Restored;

        public ProtectedClipboardWriteResult TryWrite(string text)
        {
            WriteCalls++;
            return WriteSucceeds
                ? new(true, new ClipboardTextSnapshot(true, "previous"), 77)
                : ProtectedClipboardWriteResult.Failed;
        }

        public ClipboardSnapshotRestoreResult TryRestore(
            ClipboardTextSnapshot snapshot,
            uint expectedSequenceNumber)
        {
            RestoreCalls++;
            return RestoreResult;
        }
    }

    private sealed class FakePaste : IPasteInput
    {
        public bool ModifiersReleased { get; set; } = true;
        public bool PasteSucceeds { get; set; } = true;
        public Action? AfterWait { get; set; }
        public int PasteCalls { get; private set; }

        public Task<bool> WaitForHotkeyModifiersAsync(
            HotkeyModifiers modifiers,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            AfterWait?.Invoke();
            return Task.FromResult(ModifiersReleased);
        }

        public bool TryPasteOnce()
        {
            PasteCalls++;
            return PasteSucceeds;
        }
    }

    private sealed class NoDelay : IInsertionDelay
    {
        public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken) =>
            Task.CompletedTask;
    }
}
