using System.Runtime.InteropServices;
using System.Text;

namespace Witness.Platform.Windows.Insertion;

public sealed record ClipboardTextSnapshot(bool WasCaptured, string? UnicodeText)
{
    public static ClipboardTextSnapshot Unavailable { get; } = new(false, null);
    public static ClipboardTextSnapshot Empty { get; } = new(true, null);
}

public sealed record ProtectedClipboardWriteResult(
    bool Succeeded,
    ClipboardTextSnapshot Snapshot,
    uint? SequenceNumber)
{
    public static ProtectedClipboardWriteResult Failed { get; } =
        new(false, ClipboardTextSnapshot.Unavailable, null);
}

public enum ClipboardSnapshotRestoreResult
{
    Restored,
    SkippedUnavailable,
    SkippedSequenceChanged,
    Failed,
}

public interface IClipboardNativeApi
{
    uint RegisterFormat(string name);
    bool Open(nint ownerWindow);
    bool Empty();
    bool HasFormat(uint format);
    bool TryReadUnicodeText(out string? value);
    bool TrySetBytes(uint format, byte[] data);
    uint GetSequenceNumber();
    bool Close();
}

/// <summary>
/// Writes clipboard text only after all Windows history, cloud and monitor
/// exclusions are present. Clipboard contents are never logged or persisted.
/// Call this service from its owning STA/UI thread.
/// </summary>
public sealed class ProtectedClipboardService
{
    public const uint UnicodeTextFormat = 13;
    public const string ExcludeMonitorFormatName = "ExcludeClipboardContentFromMonitorProcessing";
    public const string IncludeHistoryFormatName = "CanIncludeInClipboardHistory";
    public const string UploadToCloudFormatName = "CanUploadToCloudClipboard";

    private static readonly byte[] DisabledDword = new byte[sizeof(uint)];

    private readonly IClipboardNativeApi native;
    private readonly nint ownerWindow;

    public ProtectedClipboardService(nint ownerWindow)
        : this(new Win32ClipboardNativeApi(), ownerWindow)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
    }

    public ProtectedClipboardService(IClipboardNativeApi native, nint ownerWindow)
    {
        ArgumentNullException.ThrowIfNull(native);
        if (ownerWindow == 0)
            throw new ArgumentException("A non-zero owner window is required for clipboard ownership.", nameof(ownerWindow));
        this.native = native;
        this.ownerWindow = ownerWindow;
    }

    public ProtectedClipboardWriteResult TryWrite(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (!TryGetProtectionFormats(out var formats) || !native.Open(ownerWindow))
            return ProtectedClipboardWriteResult.Failed;

        var snapshot = CaptureSnapshot();
        var succeeded = false;
        try
        {
            if (!native.Empty()) return ProtectedClipboardWriteResult.Failed;
            succeeded = TrySetProtectionFormats(formats)
                && native.TrySetBytes(UnicodeTextFormat, EncodeUnicodeText(text));
            if (!succeeded)
            {
                // Remove any partially written formats. In particular, text is
                // always last, so a privacy-format failure can never expose it.
                native.Empty();
            }
        }
        finally
        {
            if (!native.Close()) succeeded = false;
        }

        return succeeded
            ? new(true, snapshot, native.GetSequenceNumber())
            : ProtectedClipboardWriteResult.Failed;
    }

    public ClipboardSnapshotRestoreResult TryRestore(
        ClipboardTextSnapshot snapshot,
        uint expectedSequenceNumber)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!snapshot.WasCaptured)
            return ClipboardSnapshotRestoreResult.SkippedUnavailable;

        ClipboardFormatIds formats = default;
        if (snapshot.UnicodeText is not null && !TryGetProtectionFormats(out formats))
            return ClipboardSnapshotRestoreResult.Failed;
        if (!native.Open(ownerWindow)) return ClipboardSnapshotRestoreResult.Failed;

        var result = ClipboardSnapshotRestoreResult.Failed;
        try
        {
            // Check while the clipboard is locked so another process cannot win
            // the check/write race and have its newer value overwritten.
            if (native.GetSequenceNumber() != expectedSequenceNumber)
            {
                result = ClipboardSnapshotRestoreResult.SkippedSequenceChanged;
            }
            else if (!native.Empty())
            {
                result = ClipboardSnapshotRestoreResult.Failed;
            }
            else if (snapshot.UnicodeText is null)
            {
                result = ClipboardSnapshotRestoreResult.Restored;
            }
            else if (TrySetProtectionFormats(formats)
                && native.TrySetBytes(UnicodeTextFormat, EncodeUnicodeText(snapshot.UnicodeText)))
            {
                result = ClipboardSnapshotRestoreResult.Restored;
            }
            else
            {
                native.Empty();
            }
        }
        finally
        {
            if (!native.Close()) result = ClipboardSnapshotRestoreResult.Failed;
        }
        return result;
    }

    private ClipboardTextSnapshot CaptureSnapshot()
    {
        if (!native.HasFormat(UnicodeTextFormat)) return ClipboardTextSnapshot.Empty;
        return native.TryReadUnicodeText(out var value)
            ? new ClipboardTextSnapshot(true, value ?? string.Empty)
            : ClipboardTextSnapshot.Unavailable;
    }

    private bool TryGetProtectionFormats(out ClipboardFormatIds formats)
    {
        formats = new(
            native.RegisterFormat(ExcludeMonitorFormatName),
            native.RegisterFormat(IncludeHistoryFormatName),
            native.RegisterFormat(UploadToCloudFormatName));
        return formats.ExcludeMonitor != 0
            && formats.IncludeHistory != 0
            && formats.UploadToCloud != 0;
    }

    private bool TrySetProtectionFormats(ClipboardFormatIds formats) =>
        native.TrySetBytes(formats.ExcludeMonitor, DisabledDword)
        && native.TrySetBytes(formats.IncludeHistory, DisabledDword)
        && native.TrySetBytes(formats.UploadToCloud, DisabledDword);

    private static byte[] EncodeUnicodeText(string text) =>
        Encoding.Unicode.GetBytes(string.Concat(text, '\0'));

    private readonly record struct ClipboardFormatIds(
        uint ExcludeMonitor,
        uint IncludeHistory,
        uint UploadToCloud);
}

public sealed partial class Win32ClipboardNativeApi : IClipboardNativeApi
{
    private const uint GlobalMoveable = 0x0002;
    private const uint GlobalZeroInit = 0x0040;

    public uint RegisterFormat(string name) => NativeMethods.RegisterClipboardFormat(name);
    public bool Open(nint ownerWindow) => NativeMethods.OpenClipboard(ownerWindow);
    public bool Empty() => NativeMethods.EmptyClipboard();
    public bool HasFormat(uint format) => NativeMethods.IsClipboardFormatAvailable(format);
    public uint GetSequenceNumber() => NativeMethods.GetClipboardSequenceNumber();
    public bool Close() => NativeMethods.CloseClipboard();

    public bool TryReadUnicodeText(out string? value)
    {
        value = null;
        var memory = NativeMethods.GetClipboardData(ProtectedClipboardService.UnicodeTextFormat);
        if (memory == 0) return false;
        var size = NativeMethods.GlobalSize(memory);
        if (size == 0 || size > int.MaxValue) return false;
        var pointer = NativeMethods.GlobalLock(memory);
        if (pointer == 0) return false;
        try
        {
            var bytes = new byte[(int)size];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            var terminator = FindUtf16Terminator(bytes);
            value = Encoding.Unicode.GetString(bytes, 0, terminator);
            return true;
        }
        finally
        {
            NativeMethods.GlobalUnlock(memory);
        }
    }

    public bool TrySetBytes(uint format, byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        var memory = NativeMethods.GlobalAlloc(GlobalMoveable | GlobalZeroInit, (nuint)Math.Max(1, data.Length));
        if (memory == 0) return false;
        var ownershipTransferred = false;
        try
        {
            var pointer = NativeMethods.GlobalLock(memory);
            if (pointer == 0) return false;
            try
            {
                if (data.Length > 0) Marshal.Copy(data, 0, pointer, data.Length);
            }
            finally
            {
                NativeMethods.GlobalUnlock(memory);
            }
            ownershipTransferred = NativeMethods.SetClipboardData(format, memory) != 0;
            return ownershipTransferred;
        }
        finally
        {
            if (!ownershipTransferred) NativeMethods.GlobalFree(memory);
        }
    }

    private static int FindUtf16Terminator(byte[] bytes)
    {
        var evenLength = bytes.Length - bytes.Length % sizeof(char);
        for (var index = 0; index + 1 < evenLength; index += 2)
        {
            if (bytes[index] == 0 && bytes[index + 1] == 0) return index;
        }
        return evenLength;
    }

    private static partial class NativeMethods
    {
        [LibraryImport("user32.dll", EntryPoint = "RegisterClipboardFormatW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
        internal static partial uint RegisterClipboardFormat(string format);

        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool OpenClipboard(nint ownerWindow);

        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool EmptyClipboard();

        [LibraryImport("user32.dll", SetLastError = true)]
        internal static partial nint SetClipboardData(uint format, nint memory);

        [LibraryImport("user32.dll", SetLastError = true)]
        internal static partial nint GetClipboardData(uint format);

        [LibraryImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool IsClipboardFormatAvailable(uint format);

        [LibraryImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool CloseClipboard();

        [LibraryImport("user32.dll")]
        internal static partial uint GetClipboardSequenceNumber();

        [LibraryImport("kernel32.dll", SetLastError = true)]
        internal static partial nint GlobalAlloc(uint flags, nuint bytes);

        [LibraryImport("kernel32.dll", SetLastError = true)]
        internal static partial nint GlobalLock(nint memory);

        [LibraryImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool GlobalUnlock(nint memory);

        [LibraryImport("kernel32.dll")]
        internal static partial nint GlobalFree(nint memory);

        [LibraryImport("kernel32.dll", SetLastError = true)]
        internal static partial nuint GlobalSize(nint memory);
    }
}
