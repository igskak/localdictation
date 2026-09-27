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

public sealed record AudioInputDevice(string Id, string DisplayName, bool IsActive, bool IsBuiltIn, bool IsSystemDefault);

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
