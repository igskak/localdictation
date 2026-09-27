using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using Witness.Core.Input;

namespace Witness.Platform.Windows.Hotkeys;

public sealed partial class GlobalHotkeyService : IHotkeyNativeRegistration, IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WmHotkey = 0x0312;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyUp = 0x0105;
    private const uint ModNoRepeat = 0x4000;

    private readonly int owningThreadId = Environment.CurrentManagedThreadId;
    private readonly HotkeyRegistrationCoordinator registration;
    private readonly LowLevelKeyboardProcedure keyboardProcedure;
    private IntPtr keyboardHook;
    private bool pressOutstanding;
    private bool disposed;

    public GlobalHotkeyService()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        registration = new HotkeyRegistrationCoordinator(this);
        keyboardProcedure = KeyboardHook;
        ComponentDispatcher.ThreadFilterMessage += FilterMessage;
        keyboardHook = NativeMethods.SetWindowsHookEx(WhKeyboardLl, keyboardProcedure, IntPtr.Zero, 0);
        if (keyboardHook == IntPtr.Zero)
        {
            ComponentDispatcher.ThreadFilterMessage -= FilterMessage;
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The global key-release hook could not be installed.");
        }
    }

    public event EventHandler? Pressed;
    public event EventHandler? Released;

    public HotkeyChord? ActiveChord => registration.ActiveChord;

    public HotkeyRegistrationResult Change(HotkeyChord chord)
    {
        VerifyOwningThread();
        ObjectDisposedException.ThrowIf(disposed, this);
        pressOutstanding = false;
        return registration.Change(chord);
    }

    bool IHotkeyNativeRegistration.TryRegister(int id, HotkeyChord chord) =>
        NativeMethods.RegisterHotKey(IntPtr.Zero, id, (uint)chord.Modifiers | ModNoRepeat, chord.VirtualKey);

    void IHotkeyNativeRegistration.Unregister(int id) => NativeMethods.UnregisterHotKey(IntPtr.Zero, id);

    public void Dispose()
    {
        if (disposed) return;
        VerifyOwningThread();
        disposed = true;
        registration.Dispose();
        ComponentDispatcher.ThreadFilterMessage -= FilterMessage;
        if (keyboardHook != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(keyboardHook);
            keyboardHook = IntPtr.Zero;
        }
        GC.SuppressFinalize(this);
    }

    private void FilterMessage(ref MSG message, ref bool handled)
    {
        if (message.message != WmHotkey || registration.ActiveId != message.wParam.ToInt32()) return;
        pressOutstanding = true;
        Pressed?.Invoke(this, EventArgs.Empty);
        handled = true;
    }

    private IntPtr KeyboardHook(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0 && pressOutstanding && registration.ActiveChord is HotkeyChord chord &&
            (message.ToInt32() == WmKeyUp || message.ToInt32() == WmSysKeyUp))
        {
            var keyboard = Marshal.PtrToStructure<LowLevelKeyboardInput>(data);
            if (keyboard.VirtualKey == chord.VirtualKey)
            {
                pressOutstanding = false;
                Released?.Invoke(this, EventArgs.Empty);
            }
        }
        return NativeMethods.CallNextHookEx(keyboardHook, code, message, data);
    }

    private void VerifyOwningThread()
    {
        if (Environment.CurrentManagedThreadId != owningThreadId)
            throw new InvalidOperationException("GlobalHotkeyService must be used and disposed on its creating UI thread.");
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct LowLevelKeyboardInput
    {
        public readonly uint VirtualKey;
        public readonly uint ScanCode;
        public readonly uint Flags;
        public readonly uint Time;
        public readonly nuint ExtraInfo;
    }

    private delegate IntPtr LowLevelKeyboardProcedure(int code, IntPtr message, IntPtr data);

    private static partial class NativeMethods
    {
        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool UnregisterHotKey(IntPtr window, int id);

        [LibraryImport("user32.dll", SetLastError = true)]
        internal static partial IntPtr SetWindowsHookEx(int hookId, LowLevelKeyboardProcedure callback, IntPtr module, uint threadId);

        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool UnhookWindowsHookEx(IntPtr hook);

        [LibraryImport("user32.dll")]
        internal static partial IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    }
}
