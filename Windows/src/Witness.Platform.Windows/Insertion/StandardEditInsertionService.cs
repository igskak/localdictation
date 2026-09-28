using System.Runtime.InteropServices;
using Witness.Core.Insertion;

namespace Witness.Platform.Windows.Insertion;

public sealed record StandardEditSnapshot(
    string Value,
    int SelectionStart,
    int SelectionLength);

public sealed record StandardEditControl(nint Window, bool IsPassword, bool IsReadOnly);

public enum DirectTextInsertionResult
{
    Unsupported,
    Protected,
    Verified,
    UnverifiedAfterWrite,
}

public interface IStandardEditNativeApi
{
    bool TryGetFocusedEdit(InsertionTarget target, out StandardEditControl? control);
    bool TryRead(StandardEditControl control, out StandardEditSnapshot? snapshot);
    bool TryReplaceSelection(StandardEditControl control, string text);
}

/// <summary>
/// Uses selection replacement only for the well-known Win32 Edit control. It
/// never calls UIA ValuePattern.SetValue, which would overwrite the whole field.
/// Any result after the write attempt is terminal so an uncertain write cannot
/// be followed by a duplicate clipboard paste.
/// </summary>
public sealed class StandardEditInsertionService
{
    private readonly IStandardEditNativeApi native;

    public StandardEditInsertionService()
        : this(new Win32StandardEditNativeApi())
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
    }

    public StandardEditInsertionService(IStandardEditNativeApi native) =>
        this.native = native ?? throw new ArgumentNullException(nameof(native));

    public bool SupportsVerifiedSelectionReplacement(InsertionTarget target) =>
        native.TryGetFocusedEdit(target, out var control)
        && control is not null
        && !control.IsPassword
        && !control.IsReadOnly
        && native.TryRead(control, out _);

    public DirectTextInsertionResult TryInsert(InsertionTarget target, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (!native.TryGetFocusedEdit(target, out var control) || control is null)
            return DirectTextInsertionResult.Unsupported;
        if (control.IsPassword) return DirectTextInsertionResult.Protected;
        if (control.IsReadOnly || !native.TryRead(control, out var before) || before is null)
            return DirectTextInsertionResult.Unsupported;

        var expected = PasteContentVerification.ExpectedValue(
            before.Value,
            before.SelectionStart,
            before.SelectionLength,
            text);
        if (expected is null) return DirectTextInsertionResult.Unsupported;

        // Once this call is made, never fall back to paste: a timeout or provider
        // failure cannot prove the target did not already accept the text.
        _ = native.TryReplaceSelection(control, text);
        return native.TryRead(control, out var after)
            && after is not null
            && string.Equals(after.Value, expected, StringComparison.Ordinal)
            ? DirectTextInsertionResult.Verified
            : DirectTextInsertionResult.UnverifiedAfterWrite;
    }
}

public sealed partial class Win32StandardEditNativeApi : IStandardEditNativeApi
{
    private const int EditPasswordStyle = 0x0020;
    private const int EditReadOnlyStyle = 0x0800;
    private const int WindowStyleIndex = -16;
    private const uint GetAncestorRoot = 2;
    private const uint MessageGetText = 0x000D;
    private const uint MessageGetTextLength = 0x000E;
    private const uint EditGetSelection = 0x00B0;
    private const uint EditReplaceSelection = 0x00C2;
    private const uint SendAbortIfHung = 0x0002;
    private const uint MessageTimeoutMilliseconds = 250;

    public bool TryGetFocusedEdit(InsertionTarget target, out StandardEditControl? control)
    {
        control = null;
        var foreground = NativeMethods.GetForegroundWindow();
        if (foreground == 0 || NativeMethods.GetAncestor(foreground, GetAncestorRoot) != target.TopLevelWindow)
            return false;

        var threadId = NativeMethods.GetWindowThreadProcessId(target.TopLevelWindow, out var processId);
        if (threadId == 0 || processId != target.ProcessId) return false;
        var information = new GuiThreadInformation { Size = (uint)Marshal.SizeOf<GuiThreadInformation>() };
        if (!NativeMethods.GetGUIThreadInfo(threadId, ref information) || information.FocusWindow == 0)
            return false;
        if (NativeMethods.GetAncestor(information.FocusWindow, GetAncestorRoot) != target.TopLevelWindow)
            return false;
        _ = NativeMethods.GetWindowThreadProcessId(information.FocusWindow, out var focusedProcessId);
        if (focusedProcessId != target.ProcessId) return false;

        var className = new char[64];
        var classLength = NativeMethods.GetClassName(information.FocusWindow, className, className.Length);
        if (classLength != 4 || !className.AsSpan(0, classLength).SequenceEqual("Edit"))
            return false;

        var style = NativeMethods.GetWindowLongPtr(information.FocusWindow, WindowStyleIndex).ToInt64();
        control = new(
            information.FocusWindow,
            IsPassword: (style & EditPasswordStyle) != 0,
            IsReadOnly: (style & EditReadOnlyStyle) != 0);
        return true;
    }

    public bool TryRead(StandardEditControl control, out StandardEditSnapshot? snapshot)
    {
        snapshot = null;
        if (!TrySend(control.Window, MessageGetTextLength, 0, 0, out var lengthResult))
            return false;
        var length = lengthResult.ToInt64();
        if (length < 0 || length > ushort.MaxValue) return false;

        var capacity = checked((int)length + 1);
        var bufferBytes = checked(capacity * sizeof(char));
        var buffer = Marshal.AllocHGlobal(bufferBytes);
        try
        {
            Marshal.Copy(new byte[bufferBytes], 0, buffer, bufferBytes);
            if (!TrySend(control.Window, MessageGetText, (nuint)capacity, buffer, out var copiedResult))
                return false;
            var copied = copiedResult.ToInt64();
            if (copied < 0 || copied > length) return false;
            var value = Marshal.PtrToStringUni(buffer, (int)copied) ?? string.Empty;

            if (!TrySend(control.Window, EditGetSelection, 0, 0, out var selectionResult))
                return false;
            var packedSelection = unchecked((uint)selectionResult.ToInt64());
            var start = (int)(packedSelection & 0xFFFF);
            var end = (int)(packedSelection >> 16);
            if (end < start || end > value.Length) return false;
            snapshot = new(value, start, end - start);
            return true;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public bool TryReplaceSelection(StandardEditControl control, string text)
    {
        var pointer = Marshal.StringToHGlobalUni(text);
        try
        {
            return TrySend(control.Window, EditReplaceSelection, 1, pointer, out _);
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    private static bool TrySend(
        nint window,
        uint message,
        nuint wordParameter,
        nint longParameter,
        out nint result) =>
        NativeMethods.SendMessageTimeout(
            window,
            message,
            wordParameter,
            longParameter,
            SendAbortIfHung,
            MessageTimeoutMilliseconds,
            out result) != 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInformation
    {
        public uint Size;
        public uint Flags;
        public nint ActiveWindow;
        public nint FocusWindow;
        public nint CaptureWindow;
        public nint MenuOwnerWindow;
        public nint MoveSizeWindow;
        public nint CaretWindow;
        public NativeRectangle CaretRectangle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRectangle
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    private static partial class NativeMethods
    {
        [LibraryImport("user32.dll")]
        internal static partial nint GetForegroundWindow();

        [LibraryImport("user32.dll")]
        internal static partial nint GetAncestor(nint window, uint flags);

        [LibraryImport("user32.dll", SetLastError = true)]
        internal static partial uint GetWindowThreadProcessId(nint window, out uint processId);

        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool GetGUIThreadInfo(uint threadId, ref GuiThreadInformation information);

        [LibraryImport("user32.dll", EntryPoint = "GetClassNameW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
        internal static partial int GetClassName(nint window, [Out] char[] className, int maximumCount);

        [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
        internal static partial nint GetWindowLongPtr(nint window, int index);

        [LibraryImport("user32.dll", EntryPoint = "SendMessageTimeoutW", SetLastError = true)]
        internal static partial nint SendMessageTimeout(
            nint window,
            uint message,
            nuint wordParameter,
            nint longParameter,
            uint flags,
            uint timeoutMilliseconds,
            out nint result);
    }
}
