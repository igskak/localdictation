using Velopack;

namespace Witness.Update;

public enum AppUpdateState
{
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading,
    ReadyToInstall,
    Installing,
    Failed,
}

public sealed record AppUpdateSnapshot(
    AppUpdateState State,
    string? Version = null,
    int? Build = null,
    string ReleaseNotes = "",
    int ProgressPercent = 0,
    string? Message = null)
{
    public static AppUpdateSnapshot Idle { get; } = new(AppUpdateState.Idle);
}

public sealed record AppUpdateCandidate(
    string Version,
    int Build,
    int ProductMajor,
    string ReleaseNotes,
    object BackendValue);

public interface IAppUpdateBackend : IDisposable
{
    Task<AppUpdateCandidate?> CheckAsync(CancellationToken cancellationToken);
    Task DownloadAsync(
        AppUpdateCandidate candidate,
        Action<int> progress,
        CancellationToken cancellationToken);
    Task ReverifyAsync(AppUpdateCandidate candidate, CancellationToken cancellationToken);
    void ApplyAndRestart(AppUpdateCandidate candidate);
}

public interface IAppUpdater : IDisposable
{
    AppUpdateSnapshot Snapshot { get; }
    event EventHandler<AppUpdateSnapshot>? StateChanged;
    Task CheckAsync(CancellationToken cancellationToken = default);
    Task DownloadAsync(CancellationToken cancellationToken = default);
    Task<bool> InstallAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// User-driven updater state machine. Construction and startup are deliberately
/// side-effect free: only CheckAsync may contact the feed, and only InstallAsync
/// may ask the backend to apply a package.
/// </summary>
public sealed class ManualAppUpdater : IAppUpdater
{
    private readonly IAppUpdateBackend backend;
    private readonly string currentVersion;
    private readonly int currentBuild;
    private readonly int productMajor;
    private readonly Func<bool> isProductBusy;
    private readonly Func<int, bool> isUpdateEntitled;
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private AppUpdateCandidate? candidate;
    private AppUpdateSnapshot snapshot = AppUpdateSnapshot.Idle;
    private bool disposed;

    public ManualAppUpdater(
        IAppUpdateBackend backend,
        string currentVersion,
        int currentBuild,
        int productMajor,
        Func<bool>? isProductBusy = null,
        Func<int, bool>? isUpdateEntitled = null)
    {
        this.backend = backend ?? throw new ArgumentNullException(nameof(backend));
        if (!SemanticVersion.TryParse(currentVersion, out _))
            throw new ArgumentException("The current version must be semantic.", nameof(currentVersion));
        if (currentBuild <= 0) throw new ArgumentOutOfRangeException(nameof(currentBuild));
        if (productMajor <= 0) throw new ArgumentOutOfRangeException(nameof(productMajor));
        this.currentVersion = currentVersion;
        this.currentBuild = currentBuild;
        this.productMajor = productMajor;
        this.isProductBusy = isProductBusy ?? (() => false);
        this.isUpdateEntitled = isUpdateEntitled ?? (_ => true);
    }

    public AppUpdateSnapshot Snapshot => Volatile.Read(ref snapshot);

    public event EventHandler<AppUpdateSnapshot>? StateChanged;

    public async Task CheckAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!await operationGate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return;
        try
        {
            Publish(new AppUpdateSnapshot(AppUpdateState.Checking));
            var found = await backend.CheckAsync(cancellationToken).ConfigureAwait(false);
            if (found is null)
            {
                candidate = null;
                Publish(new AppUpdateSnapshot(AppUpdateState.UpToDate));
                return;
            }

            ValidateCandidate(found);
            candidate = found;
            Publish(ForCandidate(AppUpdateState.Available, found));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            Publish(candidate is null
                ? AppUpdateSnapshot.Idle
                : ForCandidate(AppUpdateState.Available, candidate, message: "The update check was cancelled."));
        }
        catch (Exception error)
        {
            candidate = null;
            Publish(new AppUpdateSnapshot(AppUpdateState.Failed, Message: SafeMessage(error)));
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task DownloadAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (cancellationToken.IsCancellationRequested)
        {
            if (candidate is not null && Snapshot.State == AppUpdateState.Available)
                Publish(ForCandidate(AppUpdateState.Available, candidate, message: "The update download was cancelled."));
            return;
        }
        if (!await operationGate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return;
        try
        {
            var available = candidate;
            if (available is null || Snapshot.State != AppUpdateState.Available) return;
            Publish(ForCandidate(AppUpdateState.Downloading, available));
            await backend.DownloadAsync(
                available,
                value => PublishDownloadProgress(available, value),
                cancellationToken).ConfigureAwait(false);
            Publish(ForCandidate(AppUpdateState.ReadyToInstall, available, progress: 100));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            if (candidate is not null)
                Publish(ForCandidate(AppUpdateState.Available, candidate, message: "The update download was cancelled."));
        }
        catch (Exception error)
        {
            Publish(candidate is null
                ? new AppUpdateSnapshot(AppUpdateState.Failed, Message: SafeMessage(error))
                : ForCandidate(AppUpdateState.Failed, candidate, message: SafeMessage(error)));
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task<bool> InstallAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!await operationGate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return false;
        try
        {
            var ready = candidate;
            if (ready is null || Snapshot.State != AppUpdateState.ReadyToInstall) return false;
            if (isProductBusy())
            {
                Publish(ForCandidate(
                    AppUpdateState.ReadyToInstall,
                    ready,
                    progress: 100,
                    message: "Finish the current dictation or replay before installing."));
                return false;
            }
            if (!isUpdateEntitled(ready.ProductMajor))
            {
                Publish(ForCandidate(
                    AppUpdateState.ReadyToInstall,
                    ready,
                    progress: 100,
                    message: "The current license does not cover this update."));
                return false;
            }

            Publish(ForCandidate(AppUpdateState.Installing, ready, progress: 100));
            await backend.ReverifyAsync(ready, cancellationToken).ConfigureAwait(false);
            if (isProductBusy())
            {
                Publish(ForCandidate(
                    AppUpdateState.ReadyToInstall,
                    ready,
                    progress: 100,
                    message: "A dictation started while the update was being verified. Try again when it finishes."));
                return false;
            }
            if (!isUpdateEntitled(ready.ProductMajor))
            {
                Publish(ForCandidate(
                    AppUpdateState.ReadyToInstall,
                    ready,
                    progress: 100,
                    message: "The current license no longer covers this update."));
                return false;
            }

            backend.ApplyAndRestart(ready);
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            if (candidate is not null)
                Publish(ForCandidate(AppUpdateState.ReadyToInstall, candidate, progress: 100, message: "Installation was cancelled before apply."));
            return false;
        }
        catch (Exception error)
        {
            Publish(candidate is null
                ? new AppUpdateSnapshot(AppUpdateState.Failed, Message: SafeMessage(error))
                : ForCandidate(AppUpdateState.Failed, candidate, progress: 100, message: SafeMessage(error)));
            return false;
        }
        finally
        {
            operationGate.Release();
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        backend.Dispose();
        operationGate.Dispose();
    }

    private void ValidateCandidate(AppUpdateCandidate value)
    {
        if (value.ProductMajor != productMajor)
            throw new UpdateVerificationException("The update belongs to a different product major.");
        if (!SemanticVersion.TryParse(value.Version, out var available)
            || !SemanticVersion.TryParse(currentVersion, out var current)
            || available.CompareTo(current) <= 0
            || value.Build <= currentBuild)
            throw new UpdateVerificationException("The update is not newer than the installed build.");
    }

    private void PublishDownloadProgress(AppUpdateCandidate value, int progress) =>
        Publish(ForCandidate(AppUpdateState.Downloading, value, progress: Math.Clamp(progress, 0, 100)));

    private void Publish(AppUpdateSnapshot value)
    {
        Volatile.Write(ref snapshot, value);
        StateChanged?.Invoke(this, value);
    }

    private static AppUpdateSnapshot ForCandidate(
        AppUpdateState state,
        AppUpdateCandidate value,
        int progress = 0,
        string? message = null) => new(
            state,
            value.Version,
            value.Build,
            value.ReleaseNotes,
            progress,
            message);

    private static string SafeMessage(Exception error) => error switch
    {
        UpdateVerificationException => error.Message,
        UnauthorizedAccessException => "The update files are not accessible.",
        IOException => "The update could not be saved or read.",
        _ => "The update operation failed.",
    };
}
