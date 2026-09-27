using Witness.Core.Input;

namespace Witness.Platform.Windows.Hotkeys;

public interface IHotkeyNativeRegistration
{
    bool TryRegister(int id, HotkeyChord chord);
    void Unregister(int id);
}

public enum HotkeyRegistrationStatus
{
    Registered,
    Conflict,
}

public readonly record struct HotkeyRegistrationResult(HotkeyRegistrationStatus Status, HotkeyChord? ActiveChord);

/// <summary>Changes registration transactionally so a conflict never drops the working shortcut.</summary>
public sealed class HotkeyRegistrationCoordinator(IHotkeyNativeRegistration nativeRegistration) : IDisposable
{
    private const int FirstId = 0x5700;
    private int activeId;
    private int nextId = FirstId;

    public HotkeyChord? ActiveChord { get; private set; }
    public int? ActiveId => ActiveChord is null ? null : activeId;

    public HotkeyRegistrationResult Change(HotkeyChord chord)
    {
        chord.Validated();
        if (ActiveChord == chord) return new(HotkeyRegistrationStatus.Registered, ActiveChord);

        var candidateId = nextId++;
        if (!nativeRegistration.TryRegister(candidateId, chord))
            return new(HotkeyRegistrationStatus.Conflict, ActiveChord);

        if (ActiveChord is not null) nativeRegistration.Unregister(activeId);
        activeId = candidateId;
        ActiveChord = chord;
        return new(HotkeyRegistrationStatus.Registered, ActiveChord);
    }

    public void Clear()
    {
        if (ActiveChord is null) return;
        nativeRegistration.Unregister(activeId);
        ActiveChord = null;
        activeId = 0;
    }

    public void Dispose() => Clear();
}
