using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Input;
using Witness.Platform.Windows.Insertion;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class InsertionTargetAndInputTests
{
    [TestMethod]
    public void TargetIdentityUsesProcessAndRootWindow()
    {
        var native = new FakeTargetNative
        {
            Foreground = 20,
            Root = 10,
            ProcessId = 42,
        };
        var service = new ForegroundInsertionTargetService(native);

        var captured = service.Observe();

        Assert.IsTrue(captured.DesktopAvailable);
        Assert.AreEqual(new InsertionTarget(42, 10), captured.Target);
        Assert.IsTrue(ForegroundInsertionTargetService.IsSameTarget(captured.Target!.Value, captured));
        Assert.IsFalse(ForegroundInsertionTargetService.IsSameTarget(
            captured.Target.Value,
            new ForegroundTargetObservation(true, new InsertionTarget(42, 11))));
    }

    [TestMethod]
    public void SecureOrUnknownDesktopHasNoInsertionTarget()
    {
        foreach (var desktop in new string?[] { "Winlogon", null })
        {
            var native = new FakeTargetNative { DesktopName = desktop, Foreground = 20, Root = 10, ProcessId = 42 };
            var observation = new ForegroundInsertionTargetService(native).Observe();
            Assert.IsFalse(observation.DesktopAvailable);
            Assert.IsNull(observation.Target);
            Assert.AreEqual(0, native.ForegroundReads);
        }
    }

    [TestMethod]
    public void DisconnectedSessionHasNoInsertionTarget()
    {
        var native = new FakeTargetNative
        {
            SessionActive = false,
            Foreground = 20,
            Root = 10,
            ProcessId = 42,
        };

        var observation = new ForegroundInsertionTargetService(native).Observe();

        Assert.IsFalse(observation.DesktopAvailable);
        Assert.IsNull(observation.Target);
        Assert.AreEqual(0, native.ForegroundReads);
    }

    [TestMethod]
    public void MissingForegroundWindowDoesNotInventATarget()
    {
        var observation = new ForegroundInsertionTargetService(new FakeTargetNative()).Observe();
        Assert.IsTrue(observation.DesktopAvailable);
        Assert.IsNull(observation.Target);
    }

    [TestMethod]
    public async Task ModifierWaitIsBoundedAndCancellationAware()
    {
        var native = new FakeKeyboard { ModifierReads = new Queue<bool>([true, true, true]) };
        var delay = new FakeDelay();
        var service = new PasteInputService(native, delay, maximumPolls: 3, TimeSpan.Zero);

        Assert.IsFalse(await service.WaitForHotkeyModifiersAsync(HotkeyModifiers.Control));
        Assert.AreEqual(2, delay.Calls);

        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsExactlyAsync<OperationCanceledException>(
            () => service.WaitForHotkeyModifiersAsync(HotkeyModifiers.Control, cancellation.Token));
    }

    [TestMethod]
    public async Task ModifierWaitStopsAsSoonAsConfiguredKeysAreReleased()
    {
        var native = new FakeKeyboard { ModifierReads = new Queue<bool>([true, false]) };
        var delay = new FakeDelay();
        var service = new PasteInputService(native, delay, maximumPolls: 5, TimeSpan.Zero);

        Assert.IsTrue(await service.WaitForHotkeyModifiersAsync(HotkeyModifiers.Control));
        Assert.AreEqual(1, delay.Calls);
    }

    [TestMethod]
    public void PasteEmitsExactlyOneCtrlVChordAndNeverRetriesPartialInput()
    {
        var native = new FakeKeyboard { SendResult = 3 };
        var service = new PasteInputService(native, new FakeDelay());

        Assert.IsFalse(service.TryPasteOnce());
        Assert.AreEqual(1, native.SendCalls);
        CollectionAssert.AreEqual(
            new[]
            {
                new SynthesizedKeyInput(0x11, false),
                new SynthesizedKeyInput(0x56, false),
                new SynthesizedKeyInput(0x56, true),
                new SynthesizedKeyInput(0x11, true),
            },
            native.LastInputs!.ToArray());
    }

    private sealed class FakeTargetNative : IForegroundTargetNativeApi
    {
        public bool SessionActive { get; init; } = true;
        public string? DesktopName { get; init; } = "Default";
        public nint Foreground { get; init; }
        public nint Root { get; init; }
        public uint ProcessId { get; init; }
        public int ForegroundReads { get; private set; }

        public bool IsCurrentSessionActive() => SessionActive;

        public bool TryGetInputDesktopName(out string? name)
        {
            name = DesktopName;
            return name is not null;
        }

        public nint GetForegroundWindow()
        {
            ForegroundReads++;
            return Foreground;
        }

        public nint GetTopLevelWindow(nint window) => Root;
        public uint GetWindowProcessId(nint window) => ProcessId;
    }

    private sealed class FakeKeyboard : IKeyboardInputNativeApi
    {
        public Queue<bool> ModifierReads { get; init; } = [];
        public uint SendResult { get; init; } = 4;
        public int SendCalls { get; private set; }
        public IReadOnlyList<SynthesizedKeyInput>? LastInputs { get; private set; }

        public bool IsKeyDown(uint virtualKey) => ModifierReads.Count > 0 && ModifierReads.Dequeue();

        public uint Send(IReadOnlyList<SynthesizedKeyInput> inputs)
        {
            SendCalls++;
            LastInputs = inputs.ToArray();
            return SendResult;
        }
    }

    private sealed class FakeDelay : IInsertionDelay
    {
        public int Calls { get; private set; }

        public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.CompletedTask;
        }
    }
}
