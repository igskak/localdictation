using System.Runtime.InteropServices;
using Witness.Core.Input;
using Witness.Core.Insertion;

namespace Witness.Platform.Windows.Insertion;

public readonly record struct SynthesizedKeyInput(ushort VirtualKey, bool KeyUp);

public interface IKeyboardInputNativeApi
{
    bool IsKeyDown(uint virtualKey);
    uint Send(IReadOnlyList<SynthesizedKeyInput> inputs);
}

public interface IInsertionDelay
{
    Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken);
}

public sealed class SystemInsertionDelay : IInsertionDelay
{
    public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken) =>
        Task.Delay(delay, cancellationToken);
}

/// <summary>
/// Waits a bounded time for the registered shortcut modifiers, then emits one
/// Ctrl+V chord. A partial or blocked SendInput call is reported as failure and
/// is never retried automatically.
/// </summary>
public sealed class PasteInputService
{
    private const ushort VirtualKeyControl = 0x11;
    private const ushort VirtualKeyV = 0x56;

    private static readonly SynthesizedKeyInput[] PasteInputs =
    [
        new(VirtualKeyControl, KeyUp: false),
        new(VirtualKeyV, KeyUp: false),
        new(VirtualKeyV, KeyUp: true),
        new(VirtualKeyControl, KeyUp: true),
    ];

    private readonly IKeyboardInputNativeApi native;
    private readonly IInsertionDelay delay;
    private readonly int maximumPolls;
    private readonly TimeSpan pollInterval;

    public PasteInputService(
        int maximumPolls = 50,
        TimeSpan? pollInterval = null)
        : this(new Win32KeyboardInputNativeApi(), new SystemInsertionDelay(), maximumPolls, pollInterval)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
    }

    public PasteInputService(
        IKeyboardInputNativeApi native,
        IInsertionDelay delay,
        int maximumPolls = 50,
        TimeSpan? pollInterval = null)
    {
        this.native = native ?? throw new ArgumentNullException(nameof(native));
        this.delay = delay ?? throw new ArgumentNullException(nameof(delay));
        if (maximumPolls < 1) throw new ArgumentOutOfRangeException(nameof(maximumPolls));
        this.maximumPolls = maximumPolls;
        this.pollInterval = pollInterval ?? TimeSpan.FromMilliseconds(10);
        if (this.pollInterval < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(pollInterval));
    }

    public async Task<bool> WaitForHotkeyModifiersAsync(
        HotkeyModifiers modifiers,
        CancellationToken cancellationToken = default)
    {
        var tracker = new ModifierReleaseTracker(maximumPolls);
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var state = tracker.Observe(AnyConfiguredModifierDown(modifiers));
            if (state == ModifierReleaseState.Released) return true;
            if (state == ModifierReleaseState.TimedOut) return false;
            await delay.DelayAsync(pollInterval, cancellationToken).ConfigureAwait(false);
        }
    }

    public bool TryPasteOnce() => native.Send(PasteInputs) == PasteInputs.Length;

    private bool AnyConfiguredModifierDown(HotkeyModifiers modifiers) =>
        ((modifiers & HotkeyModifiers.Control) != 0 && native.IsKeyDown(0x11))
        || ((modifiers & HotkeyModifiers.Shift) != 0 && native.IsKeyDown(0x10))
        || ((modifiers & HotkeyModifiers.Alt) != 0 && native.IsKeyDown(0x12))
        || ((modifiers & HotkeyModifiers.Windows) != 0
            && (native.IsKeyDown(0x5B) || native.IsKeyDown(0x5C)));
}

public sealed partial class Win32KeyboardInputNativeApi : IKeyboardInputNativeApi
{
    private const uint KeyboardInputType = 1;
    private const uint KeyUpFlag = 0x0002;

    public bool IsKeyDown(uint virtualKey) => (NativeMethods.GetAsyncKeyState((int)virtualKey) & 0x8000) != 0;

    public uint Send(IReadOnlyList<SynthesizedKeyInput> inputs)
    {
        ArgumentNullException.ThrowIfNull(inputs);
        var nativeInputs = new NativeInput[inputs.Count];
        for (var index = 0; index < inputs.Count; index++)
        {
            nativeInputs[index] = new NativeInput
            {
                Type = KeyboardInputType,
                Data = new InputUnion
                {
                    Keyboard = new KeyboardInput
                    {
                        VirtualKey = inputs[index].VirtualKey,
                        Flags = inputs[index].KeyUp ? KeyUpFlag : 0,
                    },
                },
            };
        }
        return NativeMethods.SendInput((uint)nativeInputs.Length, nativeInputs, Marshal.SizeOf<NativeInput>());
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInput
    {
        public uint Type;
        public InputUnion Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public nuint ExtraInfo;
    }

    private static partial class NativeMethods
    {
        [LibraryImport("user32.dll")]
        internal static partial short GetAsyncKeyState(int virtualKey);

        [LibraryImport("user32.dll", SetLastError = true)]
        internal static partial uint SendInput(uint count, NativeInput[] inputs, int size);
    }
}
