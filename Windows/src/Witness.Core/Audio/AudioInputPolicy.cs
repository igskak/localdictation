namespace Witness.Core.Audio;

public enum AudioInputSelectionKind
{
    SystemDefault,
    BuiltIn,
    Specific,
}

public sealed record AudioInputSelection(AudioInputSelectionKind Kind, string? DeviceId = null)
{
    public static AudioInputSelection SystemDefault { get; } = new(AudioInputSelectionKind.SystemDefault);
    public static AudioInputSelection BuiltIn { get; } = new(AudioInputSelectionKind.BuiltIn);
    public static AudioInputSelection Specific(string deviceId) =>
        new(AudioInputSelectionKind.Specific, string.IsNullOrWhiteSpace(deviceId)
            ? throw new ArgumentException("A specific input requires a device ID.", nameof(deviceId))
            : deviceId);
}

public sealed record AudioInputDevice(
    string Id,
    string DisplayName,
    bool IsActive,
    bool IsBuiltIn,
    bool IsSystemDefault,
    bool IsBluetooth = false);

public enum AudioInputResolutionReason
{
    Selected,
    SpecificDeviceUnavailable,
    BuiltInDeviceUnavailable,
    NoActiveInput,
}

public sealed record AudioInputResolution(AudioInputDevice? Device, AudioInputResolutionReason Reason)
{
    public bool UsedFallback => Reason is AudioInputResolutionReason.SpecificDeviceUnavailable or AudioInputResolutionReason.BuiltInDeviceUnavailable;
}

public static class AudioInputSelectionPolicy
{
    public static AudioInputResolution Resolve(AudioInputSelection selection, IReadOnlyList<AudioInputDevice> devices)
    {
        ArgumentNullException.ThrowIfNull(selection);
        ArgumentNullException.ThrowIfNull(devices);
        var active = devices.Where(device => device.IsActive).ToArray();
        if (active.Length == 0) return new(null, AudioInputResolutionReason.NoActiveInput);
        var system = active.FirstOrDefault(device => device.IsSystemDefault) ?? active[0];
        return selection.Kind switch
        {
            AudioInputSelectionKind.SystemDefault => new(system, AudioInputResolutionReason.Selected),
            AudioInputSelectionKind.BuiltIn => active.FirstOrDefault(device => device.IsBuiltIn) is AudioInputDevice builtIn
                ? new(builtIn, AudioInputResolutionReason.Selected)
                : new(system, AudioInputResolutionReason.BuiltInDeviceUnavailable),
            AudioInputSelectionKind.Specific => active.FirstOrDefault(device => string.Equals(device.Id, selection.DeviceId, StringComparison.Ordinal)) is AudioInputDevice specific
                ? new(specific, AudioInputResolutionReason.Selected)
                : new(system, AudioInputResolutionReason.SpecificDeviceUnavailable),
            _ => throw new ArgumentOutOfRangeException(nameof(selection)),
        };
    }
}

/// <summary>RAM-only avoidance for an endpoint proven to deliver digital zero.</summary>
public sealed class SilentBluetoothEndpointMemory(TimeProvider? timeProvider = null)
{
    private static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(30);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly Dictionary<string, DateTimeOffset> silentUntil = new(StringComparer.Ordinal);

    public void RememberSilent(AudioInputDevice device)
    {
        if (device.IsBluetooth)
            silentUntil[device.Id] = clock.GetUtcNow().Add(Lifetime);
    }

    public bool ShouldAvoid(AudioInputDevice device)
    {
        if (!device.IsBluetooth || !silentUntil.TryGetValue(device.Id, out var expiry)) return false;
        if (expiry > clock.GetUtcNow()) return true;
        silentUntil.Remove(device.Id);
        return false;
    }

    public void EndpointReconnected(string endpointId) => silentUntil.Remove(endpointId);
    public void DefaultChanged() => silentUntil.Clear();
}

public static class SilentBluetoothFallbackPolicy
{
    public static AudioInputResolution Resolve(
        AudioInputSelection selection,
        IReadOnlyList<AudioInputDevice> devices,
        SilentBluetoothEndpointMemory memory)
    {
        var selected = AudioInputSelectionPolicy.Resolve(selection, devices);
        if (selected.Device is not AudioInputDevice device || !memory.ShouldAvoid(device)) return selected;
        var fallback = devices.FirstOrDefault(candidate => candidate.IsActive && !memory.ShouldAvoid(candidate));
        return fallback is null
            ? selected
            : new AudioInputResolution(fallback, AudioInputResolutionReason.SpecificDeviceUnavailable);
    }
}

/// <summary>Selection changes are staged and become active only when a new capture starts.</summary>
public sealed class DeferredAudioInputSelection(AudioInputSelection initial)
{
    public AudioInputSelection Current { get; private set; } = initial ?? throw new ArgumentNullException(nameof(initial));
    public AudioInputSelection? Pending { get; private set; }

    public void Stage(AudioInputSelection selection) => Pending = selection ?? throw new ArgumentNullException(nameof(selection));

    public AudioInputSelection BeginNextCapture()
    {
        if (Pending is not null)
        {
            Current = Pending;
            Pending = null;
        }
        return Current;
    }
}

public enum CaptureInterruptionOutcome
{
    NoSpeech,
    TranscribeBufferedAudioAndReportInterruption,
}

public static class CaptureInterruptionPolicy
{
    public static CaptureInterruptionOutcome Decide(bool hasDetectedSpeech, int bufferedFrameCount) =>
        hasDetectedSpeech && bufferedFrameCount > 0
            ? CaptureInterruptionOutcome.TranscribeBufferedAudioAndReportInterruption
            : CaptureInterruptionOutcome.NoSpeech;
}
