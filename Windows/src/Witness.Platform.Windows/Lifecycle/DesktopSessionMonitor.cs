using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Witness.Platform.Windows.Lifecycle;

public static class DesktopSessionChangePolicy
{
    public const int ConsoleDisconnect = 2;
    public const int RemoteDisconnect = 4;
    public const int SessionLogoff = 6;
    public const int SessionLock = 7;

    public static bool ShouldStopCapture(int reason) =>
        reason is ConsoleDisconnect or RemoteDisconnect or SessionLogoff or SessionLock;
}

public sealed partial class DesktopSessionMonitor : IDisposable
{
    private const int WmWtsSessionChange = 0x02B1;
    private const uint NotifyForThisSession = 0;
    private readonly IntPtr windowHandle;
    private readonly HwndSource source;
    private bool disposed;

    public DesktopSessionMonitor(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        windowHandle = new WindowInteropHelper(window).Handle;
        if (windowHandle == IntPtr.Zero)
            throw new InvalidOperationException("DesktopSessionMonitor requires an initialized window handle.");
        source = HwndSource.FromHwnd(windowHandle)
            ?? throw new InvalidOperationException("The WPF window source is unavailable.");
        source.AddHook(WindowMessage);
        if (!NativeMethods.WTSRegisterSessionNotification(windowHandle, NotifyForThisSession))
        {
            source.RemoveHook(WindowMessage);
            throw new InvalidOperationException("Windows session notifications could not be registered.");
        }
    }

    public event EventHandler? CaptureShouldStop;

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        NativeMethods.WTSUnRegisterSessionNotification(windowHandle);
        source.RemoveHook(WindowMessage);
    }

    private IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmWtsSessionChange && DesktopSessionChangePolicy.ShouldStopCapture(wParam.ToInt32()))
            CaptureShouldStop?.Invoke(this, EventArgs.Empty);
        return IntPtr.Zero;
    }

    private static partial class NativeMethods
    {
        [LibraryImport("wtsapi32.dll", SetLastError = true)]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvStdcall)])]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool WTSRegisterSessionNotification(IntPtr window, uint flags);

        [LibraryImport("wtsapi32.dll")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvStdcall)])]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool WTSUnRegisterSessionNotification(IntPtr window);
    }
}
