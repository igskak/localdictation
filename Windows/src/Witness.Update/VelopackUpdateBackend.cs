using Velopack;

namespace Witness.Update;

public sealed class VelopackUpdateBackend : IAppUpdateBackend
{
    private readonly VerifiedManifestUpdateSource source;
    private readonly UpdateManager manager;
    private UpdateInfo? updateInfo;

    public VelopackUpdateBackend(VerifiedManifestUpdateSource source, string channel)
    {
        this.source = source ?? throw new ArgumentNullException(nameof(source));
        ArgumentException.ThrowIfNullOrWhiteSpace(channel);
        manager = new UpdateManager(
            source,
            new UpdateOptions
            {
                AllowVersionDowngrade = false,
                ExplicitChannel = channel,
                MaximumDeltasBeforeFallback = -1,
            });
    }

    public async Task<AppUpdateCandidate?> CheckAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        updateInfo = await manager.CheckForUpdatesAsync().ConfigureAwait(false);
        if (updateInfo is null) return null;

        var verified = source.VerifiedManifest
            ?? throw new UpdateVerificationException("The update manifest was not retained after feed verification.");
        var target = updateInfo.TargetFullRelease;
        if (!string.Equals(
                target.Version.ToNormalizedString(),
                SemanticVersion.Parse(verified.Manifest.Version).ToNormalizedString(),
                StringComparison.Ordinal))
            throw new UpdateVerificationException("Velopack selected a release different from the signed manifest.");

        return new AppUpdateCandidate(
            verified.Manifest.Version,
            verified.Manifest.Build,
            verified.Manifest.ProductMajor,
            verified.Manifest.ReleaseNotes,
            updateInfo);
    }

    public async Task DownloadAsync(
        AppUpdateCandidate candidate,
        Action<int> progress,
        CancellationToken cancellationToken)
    {
        var info = RequireInfo(candidate);
        await manager.DownloadUpdatesAsync(info, progress, cancellationToken).ConfigureAwait(false);
    }

    public async Task ReverifyAsync(AppUpdateCandidate candidate, CancellationToken cancellationToken)
    {
        var info = RequireInfo(candidate);
        await source.ReverifyDownloadedPackageAsync(info.TargetFullRelease, cancellationToken).ConfigureAwait(false);
    }

    public void ApplyAndRestart(AppUpdateCandidate candidate)
    {
        var info = RequireInfo(candidate);
        manager.WaitExitThenApplyUpdates(info.TargetFullRelease, silent: false, restart: true, restartArgs: []);
    }

    public void Dispose() => source.Dispose();

    private UpdateInfo RequireInfo(AppUpdateCandidate candidate)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        if (candidate.BackendValue is not UpdateInfo info || !ReferenceEquals(info, updateInfo))
            throw new UpdateVerificationException("The update candidate does not belong to the current verified operation.");
        return info;
    }
}
