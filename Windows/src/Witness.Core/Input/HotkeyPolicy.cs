namespace Witness.Core.Input;

[Flags]
public enum HotkeyModifiers : uint
{
    None = 0,
    Alt = 1,
    Control = 2,
    Shift = 4,
    Windows = 8,
}

public readonly record struct HotkeyChord(HotkeyModifiers Modifiers, uint VirtualKey)
{
    public HotkeyChord Validated()
    {
        const HotkeyModifiers supported = HotkeyModifiers.Alt | HotkeyModifiers.Control | HotkeyModifiers.Shift | HotkeyModifiers.Windows;
        if (VirtualKey is < 1 or > 254) throw new ArgumentOutOfRangeException(nameof(VirtualKey));
        if ((Modifiers & ~supported) != 0) throw new ArgumentOutOfRangeException(nameof(Modifiers));
        if (Modifiers == HotkeyModifiers.None) throw new ArgumentException("A global hotkey must include a modifier.", nameof(Modifiers));
        return this;
    }
}

public enum HotkeyActivationMode
{
    Hold,
    Toggle,
}

public enum HotkeyAction
{
    None,
    BeginRecording,
    EndRecording,
}

/// <summary>Pure press/release/repeat policy shared by the Win32 adapter and tests.</summary>
public sealed class HotkeyGestureStateMachine(HotkeyActivationMode mode)
{
    public HotkeyActivationMode Mode { get; private set; } = mode;
    public bool IsRecordingRequested { get; private set; }
    public bool IsKeyDown { get; private set; }

    public HotkeyAction Press(bool isRepeat = false)
    {
        if (isRepeat || IsKeyDown) return HotkeyAction.None;
        IsKeyDown = true;
        if (Mode == HotkeyActivationMode.Hold)
        {
            if (IsRecordingRequested) return HotkeyAction.None;
            IsRecordingRequested = true;
            return HotkeyAction.BeginRecording;
        }
        IsRecordingRequested = !IsRecordingRequested;
        return IsRecordingRequested ? HotkeyAction.BeginRecording : HotkeyAction.EndRecording;
    }

    public HotkeyAction Release()
    {
        if (!IsKeyDown) return HotkeyAction.None;
        IsKeyDown = false;
        if (Mode != HotkeyActivationMode.Hold || !IsRecordingRequested) return HotkeyAction.None;
        IsRecordingRequested = false;
        return HotkeyAction.EndRecording;
    }

    public HotkeyAction Cancel()
    {
        IsKeyDown = false;
        if (!IsRecordingRequested) return HotkeyAction.None;
        IsRecordingRequested = false;
        return HotkeyAction.EndRecording;
    }

    public HotkeyAction ChangeMode(HotkeyActivationMode next)
    {
        var action = Cancel();
        Mode = next;
        return action;
    }
}
