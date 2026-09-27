using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Input;

namespace Witness.Core.Tests;

[TestClass]
public sealed class HotkeyPolicyTests
{
    [TestMethod]
    public void HoldModeStartsOnPressAndEndsOnRelease()
    {
        var state = new HotkeyGestureStateMachine(HotkeyActivationMode.Hold);
        Assert.AreEqual(HotkeyAction.BeginRecording, state.Press());
        Assert.AreEqual(HotkeyAction.None, state.Press(isRepeat: true));
        Assert.AreEqual(HotkeyAction.EndRecording, state.Release());
        Assert.AreEqual(HotkeyAction.None, state.Release());
    }

    [TestMethod]
    public void ToggleModeChangesOnlyOnDistinctPresses()
    {
        var state = new HotkeyGestureStateMachine(HotkeyActivationMode.Toggle);
        Assert.AreEqual(HotkeyAction.BeginRecording, state.Press());
        Assert.AreEqual(HotkeyAction.None, state.Press());
        Assert.AreEqual(HotkeyAction.None, state.Release());
        Assert.AreEqual(HotkeyAction.EndRecording, state.Press());
    }

    [TestMethod]
    public void CancellingOrChangingModeEndsAnActiveRequest()
    {
        var state = new HotkeyGestureStateMachine(HotkeyActivationMode.Toggle);
        state.Press();
        Assert.AreEqual(HotkeyAction.EndRecording, state.ChangeMode(HotkeyActivationMode.Hold));
        Assert.AreEqual(HotkeyActivationMode.Hold, state.Mode);
        Assert.IsFalse(state.IsRecordingRequested);
    }

    [TestMethod]
    public void ChordRequiresSupportedModifierAndValidVirtualKey()
    {
        Assert.ThrowsExactly<ArgumentException>(() => new HotkeyChord(HotkeyModifiers.None, 65).Validated());
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() => new HotkeyChord(HotkeyModifiers.Control, 0).Validated());
        Assert.AreEqual(new HotkeyChord(HotkeyModifiers.Control | HotkeyModifiers.Shift, 65),
            new HotkeyChord(HotkeyModifiers.Control | HotkeyModifiers.Shift, 65).Validated());
    }
}
