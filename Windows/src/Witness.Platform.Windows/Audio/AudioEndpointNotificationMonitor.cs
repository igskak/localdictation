using System.Runtime.InteropServices;

namespace Witness.Platform.Windows.Audio;

/// <summary>
/// Thin Core Audio notification adapter. Its callbacks intentionally carry no
/// audio or UI work; a session decides whether its selection follows a default
/// endpoint and reopens only on its packet worker.
/// </summary>
public sealed class AudioEndpointNotificationMonitor : IAudioRouteChangeMonitor, IMMNotificationClient
{
    private IMMDeviceEnumerator? enumerator;
    private bool started;
    private bool disposed;

    public event EventHandler? RouteMayHaveChanged;

    public void Start()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (started) return;
        enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        Marshal.ThrowExceptionForHR(enumerator.RegisterEndpointNotificationCallback(this));
        started = true;
    }

    public void Dispose()
    {
        if (disposed) return;
        if (started && enumerator is not null)
            _ = enumerator.UnregisterEndpointNotificationCallback(this);
        if (enumerator is not null)
            Marshal.ReleaseComObject(enumerator);
        enumerator = null;
        disposed = true;
    }

    public void OnDeviceStateChanged(string deviceId, uint newState) => Notify();
    public void OnDeviceAdded(string deviceId) => Notify();
    public void OnDeviceRemoved(string deviceId) => Notify();
    public void OnPropertyValueChanged(string deviceId, PropertyKey key) => Notify();

    public void OnDefaultDeviceChanged(EDataFlow flow, ERole role, string? defaultDeviceId)
    {
        if (flow == EDataFlow.Capture) Notify();
    }

    private void Notify()
    {
        try
        {
            RouteMayHaveChanged?.Invoke(this, EventArgs.Empty);
        }
        catch
        {
            // COM callbacks cannot carry managed exceptions back into Core Audio.
        }
    }
}

internal enum EDataFlow { Render, Capture, All }
internal enum ERole { Console, Multimedia, Communications }

[StructLayout(LayoutKind.Sequential)]
internal struct PropertyKey
{
    public Guid FormatId;
    public uint PropertyId;
}

[ComImport]
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator
{
    int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IntPtr devices);
    int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IntPtr endpoint);
    int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr device);
    int RegisterEndpointNotificationCallback(IMMNotificationClient client);
    int UnregisterEndpointNotificationCallback(IMMNotificationClient client);
}

[ComImport]
[Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMNotificationClient
{
    void OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string deviceId, uint newState);
    void OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
    void OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
    void OnDefaultDeviceChanged(EDataFlow flow, ERole role, [MarshalAs(UnmanagedType.LPWStr)] string? defaultDeviceId);
    void OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string deviceId, PropertyKey key);
}

[ComImport]
[Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class MMDeviceEnumeratorComObject;
