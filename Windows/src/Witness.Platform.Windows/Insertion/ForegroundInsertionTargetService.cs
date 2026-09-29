using System.Runtime.InteropServices;

namespace Witness.Platform.Windows.Insertion;

public readonly record struct InsertionTarget(uint ProcessId, nint TopLevelWindow);

public sealed record ForegroundTargetObservation(
    bool DesktopAvailable,
    InsertionTarget? Target);

public interface IForegroundTargetNativeApi
{
    bool IsCurrentSessionActive();
    bool TryGetInputDesktopName(out string? name);
    nint GetForegroundWindow();
    nint GetTopLevelWindow(nint window);
    uint GetWindowProcessId(nint window);
}

public interface IInsertionTargetObserver
{
    ForegroundTargetObservation Observe();
}

/// <summary>
/// Observes but never activates or restores another application's window.
/// A target identity includes both its process and root HWND so same-process
/// tab/window changes cannot silently redirect dictated text.
/// </summary>
public sealed class ForegroundInsertionTargetService : IInsertionTargetObserver
{
    private readonly IForegroundTargetNativeApi native;

    public ForegroundInsertionTargetService()
        : this(new Win32ForegroundTargetNativeApi())
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
    }

    public ForegroundInsertionTargetService(IForegroundTargetNativeApi native) =>
        this.native = native ?? throw new ArgumentNullException(nameof(native));

    public ForegroundTargetObservation Observe()
    {
        if (!native.IsCurrentSessionActive()
            || !native.TryGetInputDesktopName(out var desktopName)
            || !string.Equals(desktopName, "Default", StringComparison.OrdinalIgnoreCase))
        {
            return new(false, null);
        }

        var foreground = native.GetForegroundWindow();
        if (foreground == 0) return new(true, null);
        var root = native.GetTopLevelWindow(foreground);
        if (root == 0) return new(true, null);
        var processId = native.GetWindowProcessId(root);
        return processId == 0
            ? new(true, null)
            : new(true, new InsertionTarget(processId, root));
    }

    public static bool IsSameTarget(InsertionTarget captured, ForegroundTargetObservation current) =>
        current.DesktopAvailable && current.Target == captured;
}

public sealed partial class Win32ForegroundTargetNativeApi : IForegroundTargetNativeApi
{
    private const uint DesktopReadObjects = 0x0001;
    private const uint GetAncestorRoot = 2;
    private const int UserObjectName = 2;
    private const uint CurrentSession = uint.MaxValue;
    private const int ConnectStateInformation = 8;
    private const int ActiveSessionState = 0;

    public bool IsCurrentSessionActive()
    {
        if (!NativeMethods.WTSQuerySessionInformation(
            0,
            CurrentSession,
            ConnectStateInformation,
            out var buffer,
            out var returnedBytes))
        {
            return false;
        }
        try
        {
            return returnedBytes >= sizeof(int)
                && Marshal.ReadInt32(buffer) == ActiveSessionState;
        }
        finally
        {
            NativeMethods.WTSFreeMemory(buffer);
        }
    }

    public bool TryGetInputDesktopName(out string? name)
    {
        name = null;
        var desktop = NativeMethods.OpenInputDesktop(0, false, DesktopReadObjects);
        if (desktop == 0) return false;
        try
        {
            _ = NativeMethods.GetUserObjectInformation(desktop, UserObjectName, 0, 0, out var requiredBytes);
            if (requiredBytes < sizeof(char) || requiredBytes > 4_096) return false;
            var buffer = Marshal.AllocHGlobal((int)requiredBytes);
            try
            {
                if (!NativeMethods.GetUserObjectInformation(
                    desktop,
                    UserObjectName,
                    buffer,
                    requiredBytes,
                    out _))
                {
                    return false;
                }
                name = Marshal.PtrToStringUni(buffer);
                return !string.IsNullOrEmpty(name);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        finally
        {
            NativeMethods.CloseDesktop(desktop);
        }
    }

    public nint GetForegroundWindow() => NativeMethods.GetForegroundWindow();

    public nint GetTopLevelWindow(nint window) =>
        NativeMethods.GetAncestor(window, GetAncestorRoot);

    public uint GetWindowProcessId(nint window)
    {
        _ = NativeMethods.GetWindowThreadProcessId(window, out var processId);
        return processId;
    }

    private static partial class NativeMethods
    {
        [LibraryImport("user32.dll", SetLastError = true)]
        internal static partial nint OpenInputDesktop(
            uint flags,
            [MarshalAs(UnmanagedType.Bool)] bool inherit,
            uint desiredAccess);

        [LibraryImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool CloseDesktop(nint desktop);

        [LibraryImport("user32.dll", EntryPoint = "GetUserObjectInformationW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool GetUserObjectInformation(
            nint handle,
            int index,
            nint information,
            uint length,
            out uint needed);

        [LibraryImport("user32.dll")]
        internal static partial nint GetForegroundWindow();

        [LibraryImport("user32.dll")]
        internal static partial nint GetAncestor(nint window, uint flags);

        [LibraryImport("user32.dll", SetLastError = true)]
        internal static partial uint GetWindowThreadProcessId(nint window, out uint processId);

        [LibraryImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool WTSQuerySessionInformation(
            nint server,
            uint sessionId,
            int informationClass,
            out nint buffer,
            out uint returnedBytes);

        [LibraryImport("wtsapi32.dll")]
        internal static partial void WTSFreeMemory(nint memory);
    }
}
