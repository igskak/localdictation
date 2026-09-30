namespace Witness.Core.Licensing;

public enum ActivationErrorKind
{
    NotConfigured,
    DeviceIdentityUnavailable,
    InvalidEmail,
    Unreachable,
    Rejected,
    DeviceLimitReached,
}

public sealed class ActivationException : Exception
{
    public ActivationException(ActivationErrorKind kind, string message) : base(message)
    {
        Kind = kind;
    }

    public ActivationException(ActivationErrorKind kind, string message, Exception innerException)
        : base(message, innerException)
    {
        Kind = kind;
    }

    public ActivationErrorKind Kind { get; }
}

public interface IActivationBackend
{
    bool IsConfigured { get; }
    Task<string> RequestKeyAsync(string email, string deviceId, CancellationToken cancellationToken = default);
    Task<bool> ReleaseDeviceAsync(string key, string deviceId, CancellationToken cancellationToken = default);
}

public enum DeviceReleaseOutcomeKind
{
    RemovedLocally,
    ReleasedEverywhere,
    RemovedLocallyOnly,
}

public sealed record DeviceReleaseOutcome(DeviceReleaseOutcomeKind Kind, string? Warning = null);

public sealed class UnconfiguredActivationBackend : IActivationBackend
{
    public bool IsConfigured => false;

    public Task<string> RequestKeyAsync(string email, string deviceId, CancellationToken cancellationToken = default) =>
        Task.FromException<string>(new ActivationException(
            ActivationErrorKind.NotConfigured,
            "This build has no activation service. Paste a license key instead."));

    public Task<bool> ReleaseDeviceAsync(string key, string deviceId, CancellationToken cancellationToken = default) =>
        Task.FromException<bool>(new ActivationException(
            ActivationErrorKind.NotConfigured,
            "This build has no activation service."));
}

public static class EmailAddress
{
    public static bool LooksComplete(string? value)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed.Contains(' ')) return false;
        var at = trimmed.IndexOf('@');
        if (at <= 0 || at != trimmed.LastIndexOf('@')) return false;
        var dot = trimmed.IndexOf('.', at + 1);
        return dot > at + 1 && dot < trimmed.Length - 1;
    }
}
