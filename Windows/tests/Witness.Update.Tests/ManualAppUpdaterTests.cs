using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Witness.Update.Tests;

[TestClass]
public sealed class ManualAppUpdaterTests
{
    [TestMethod]
    public void ConstructionDoesNotCheckDownloadOrInstall()
    {
        using var backend = new FakeBackend(Candidate());
        using var updater = CreateUpdater(backend);

        Assert.AreEqual(AppUpdateState.Idle, updater.Snapshot.State);
        Assert.AreEqual(0, backend.CheckCount);
        Assert.AreEqual(0, backend.DownloadCount);
        Assert.AreEqual(0, backend.ApplyCount);
    }

    [TestMethod]
    public async Task UserDrivesCheckDownloadReverifyAndApply()
    {
        using var backend = new FakeBackend(Candidate());
        using var updater = CreateUpdater(backend);
        var states = new List<AppUpdateState>();
        updater.StateChanged += (_, snapshot) => states.Add(snapshot.State);

        await updater.CheckAsync();
        Assert.AreEqual(AppUpdateState.Available, updater.Snapshot.State);
        Assert.AreEqual("Synthetic notes", updater.Snapshot.ReleaseNotes);

        await updater.DownloadAsync();
        Assert.AreEqual(AppUpdateState.ReadyToInstall, updater.Snapshot.State);
        Assert.AreEqual(100, updater.Snapshot.ProgressPercent);

        Assert.IsTrue(await updater.InstallAsync());
        Assert.AreEqual(AppUpdateState.Installing, updater.Snapshot.State);
        Assert.AreEqual(1, backend.ReverifyCount);
        Assert.AreEqual(1, backend.ApplyCount);
        CollectionAssert.Contains(states, AppUpdateState.Checking);
        CollectionAssert.Contains(states, AppUpdateState.Downloading);
    }

    [TestMethod]
    public async Task SecondClickDoesNotStartConcurrentCheck()
    {
        using var backend = new FakeBackend(Candidate()) { HoldCheck = true };
        using var updater = CreateUpdater(backend);

        var first = updater.CheckAsync();
        await backend.CheckStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
        await updater.CheckAsync();
        Assert.AreEqual(1, backend.CheckCount);

        backend.ReleaseCheck.TrySetResult();
        await first;
        Assert.AreEqual(AppUpdateState.Available, updater.Snapshot.State);
    }

    [TestMethod]
    public async Task BusyDictationDefersApplyWithoutTouchingBackend()
    {
        var busy = true;
        using var backend = new FakeBackend(Candidate());
        using var updater = CreateUpdater(backend, isBusy: () => busy);
        await updater.CheckAsync();
        await updater.DownloadAsync();

        Assert.IsFalse(await updater.InstallAsync());
        Assert.AreEqual(AppUpdateState.ReadyToInstall, updater.Snapshot.State);
        Assert.AreEqual(0, backend.ReverifyCount);
        Assert.AreEqual(0, backend.ApplyCount);

        busy = false;
        Assert.IsTrue(await updater.InstallAsync());
        Assert.AreEqual(1, backend.ApplyCount);
    }

    [TestMethod]
    public async Task EntitlementIsCheckedImmediatelyBeforeApply()
    {
        var entitled = true;
        using var backend = new FakeBackend(Candidate())
        {
            AfterReverify = () => entitled = false,
        };
        using var updater = CreateUpdater(backend, isEntitled: _ => entitled);
        await updater.CheckAsync();
        await updater.DownloadAsync();

        Assert.IsFalse(await updater.InstallAsync());
        Assert.AreEqual(AppUpdateState.ReadyToInstall, updater.Snapshot.State);
        Assert.AreEqual(1, backend.ReverifyCount);
        Assert.AreEqual(0, backend.ApplyCount);
    }

    [TestMethod]
    public async Task CancelledDownloadReturnsToAvailableAndNeverApplies()
    {
        using var backend = new FakeBackend(Candidate()) { CancelDownload = true };
        using var updater = CreateUpdater(backend);
        await updater.CheckAsync();
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await updater.DownloadAsync(cancellation.Token);

        Assert.AreEqual(AppUpdateState.Available, updater.Snapshot.State);
        Assert.AreEqual(0, backend.ApplyCount);
    }

    [TestMethod]
    [DataRow("0.0.9", 2, 1)]
    [DataRow("0.1.1", 1, 1)]
    [DataRow("0.1.1", 2, 2)]
    public async Task DowngradeNonIncreasingBuildAndOtherMajorFailClosed(
        string version,
        int build,
        int major)
    {
        using var backend = new FakeBackend(Candidate(version, build, major));
        using var updater = CreateUpdater(backend);

        await updater.CheckAsync();

        Assert.AreEqual(AppUpdateState.Failed, updater.Snapshot.State);
        Assert.AreEqual(0, backend.DownloadCount);
        Assert.AreEqual(0, backend.ApplyCount);
    }

    private static ManualAppUpdater CreateUpdater(
        FakeBackend backend,
        Func<bool>? isBusy = null,
        Func<int, bool>? isEntitled = null) => new(
            backend,
            currentVersion: "0.1.0",
            currentBuild: 1,
            productMajor: 1,
            isBusy,
            isEntitled);

    private static AppUpdateCandidate Candidate(
        string version = "0.1.1",
        int build = 2,
        int major = 1) => new(
            version,
            build,
            major,
            "Synthetic notes",
            new object());

    private sealed class FakeBackend(AppUpdateCandidate? candidate) : IAppUpdateBackend
    {
        public int CheckCount { get; private set; }
        public int DownloadCount { get; private set; }
        public int ReverifyCount { get; private set; }
        public int ApplyCount { get; private set; }
        public bool HoldCheck { get; init; }
        public bool CancelDownload { get; init; }
        public Action? AfterReverify { get; init; }
        public TaskCompletionSource CheckStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource ReleaseCheck { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<AppUpdateCandidate?> CheckAsync(CancellationToken cancellationToken)
        {
            CheckCount++;
            CheckStarted.TrySetResult();
            if (HoldCheck) await ReleaseCheck.Task.WaitAsync(cancellationToken);
            return candidate;
        }

        public Task DownloadAsync(
            AppUpdateCandidate value,
            Action<int> progress,
            CancellationToken cancellationToken)
        {
            _ = value;
            DownloadCount++;
            if (CancelDownload) cancellationToken.ThrowIfCancellationRequested();
            progress(37);
            progress(100);
            return Task.CompletedTask;
        }

        public Task ReverifyAsync(AppUpdateCandidate value, CancellationToken cancellationToken)
        {
            _ = value;
            cancellationToken.ThrowIfCancellationRequested();
            ReverifyCount++;
            AfterReverify?.Invoke();
            return Task.CompletedTask;
        }

        public void ApplyAndRestart(AppUpdateCandidate value)
        {
            _ = value;
            ApplyCount++;
        }

        public void Dispose() { }
    }
}
