using System.Security.Cryptography;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Models;

namespace Witness.Core.Tests;

[TestClass]
public sealed class ModelManagerTests
{
    [TestMethod]
    public async Task ExistingVerifiedModelIsReusedOfflineWithoutDisclosure()
    {
        using var directory = new TemporaryDirectory();
        var bytes = "verified-model"u8.ToArray();
        var artifact = ArtifactFor(bytes);
        await File.WriteAllBytesAsync(Path.Combine(directory.Path, artifact.FileName), bytes);
        var download = new RecordingDownloadClient(bytes);
        await using var manager = CreateManager(artifact, directory.Path, download);

        var result = await manager.PrepareAsync(downloadDisclosureAccepted: false);

        Assert.AreEqual(ModelPreparationStatus.Ready, result.Status);
        Assert.AreEqual(0, download.CallCount);
        Assert.IsTrue(File.Exists(result.ModelPath));
    }

    [TestMethod]
    public async Task MissingModelRequiresDisclosureBeforeNetworkAccess()
    {
        using var directory = new TemporaryDirectory();
        var bytes = "new-model"u8.ToArray();
        var artifact = ArtifactFor(bytes);
        var download = new RecordingDownloadClient(bytes);
        await using var manager = CreateManager(artifact, directory.Path, download);

        var result = await manager.PrepareAsync(downloadDisclosureAccepted: false);

        Assert.AreEqual(ModelPreparationStatus.DisclosureRequired, result.Status);
        Assert.AreEqual(bytes.Length, result.RequiredBytes);
        Assert.AreEqual(0, download.CallCount);
    }

    [TestMethod]
    public async Task DisclosureCanBeAcceptedOnTheNextAttempt()
    {
        using var directory = new TemporaryDirectory();
        var bytes = "accepted-model"u8.ToArray();
        var artifact = ArtifactFor(bytes);
        var download = new RecordingDownloadClient(bytes);
        await using var manager = CreateManager(artifact, directory.Path, download);

        var disclosure = await manager.PrepareAsync(downloadDisclosureAccepted: false);
        var accepted = await manager.PrepareAsync(downloadDisclosureAccepted: true);

        Assert.AreEqual(ModelPreparationStatus.DisclosureRequired, disclosure.Status);
        Assert.AreEqual(ModelPreparationStatus.Ready, accepted.Status);
        Assert.AreEqual(1, download.CallCount);
    }

    [TestMethod]
    public async Task DownloadIsVerifiedAndCommittedAtomically()
    {
        using var directory = new TemporaryDirectory();
        var bytes = Enumerable.Range(0, 257).Select(index => (byte)(index % 251)).ToArray();
        var artifact = ArtifactFor(bytes);
        var download = new RecordingDownloadClient(bytes);
        await using var manager = CreateManager(artifact, directory.Path, download);
        var stages = new List<ModelPreparationStage>();
        manager.ProgressChanged += (_, progress) => stages.Add(progress.Stage);

        var result = await manager.PrepareAsync(downloadDisclosureAccepted: true);

        Assert.AreEqual(ModelPreparationStatus.Ready, result.Status);
        CollectionAssert.AreEqual(bytes, await File.ReadAllBytesAsync(result.ModelPath!));
        Assert.IsFalse(File.Exists(Path.Combine(directory.Path, artifact.FileName + ".partial")));
        CollectionAssert.Contains(stages, ModelPreparationStage.Downloading);
        Assert.AreEqual(ModelPreparationStage.Ready, stages[^1]);
    }

    [TestMethod]
    public async Task ConcurrentCallersShareOneDownload()
    {
        using var directory = new TemporaryDirectory();
        var bytes = "one-operation"u8.ToArray();
        var artifact = ArtifactFor(bytes);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var download = new RecordingDownloadClient(bytes, release.Task);
        await using var manager = CreateManager(artifact, directory.Path, download);

        var first = manager.PrepareAsync(downloadDisclosureAccepted: true);
        await download.Opened.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = manager.PrepareAsync(downloadDisclosureAccepted: true);
        release.SetResult();

        var results = await Task.WhenAll(first, second);
        Assert.IsTrue(results.All(result => result.IsReady));
        Assert.AreEqual(1, download.CallCount);
    }

    [TestMethod]
    public async Task CancellationRemovesPartialAndAllowsRetry()
    {
        using var directory = new TemporaryDirectory();
        var bytes = "retry-after-cancel"u8.ToArray();
        var artifact = ArtifactFor(bytes);
        var download = new RecordingDownloadClient(bytes, Task.Delay(Timeout.InfiniteTimeSpan));
        await using var manager = CreateManager(artifact, directory.Path, download);

        var cancelled = manager.PrepareAsync(downloadDisclosureAccepted: true);
        await download.Opened.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.IsTrue(manager.CancelActive());
        Assert.AreEqual(ModelPreparationStatus.Cancelled, (await cancelled).Status);
        Assert.IsFalse(File.Exists(Path.Combine(directory.Path, artifact.FileName + ".partial")));

        download.Delay = Task.CompletedTask;
        var retried = await manager.PrepareAsync(downloadDisclosureAccepted: true);
        Assert.AreEqual(ModelPreparationStatus.Ready, retried.Status);
        Assert.AreEqual(2, download.CallCount);
    }

    [TestMethod]
    public async Task CorruptDownloadIsRejectedAndRetryCanReplaceIt()
    {
        using var directory = new TemporaryDirectory();
        var expected = "expected"u8.ToArray();
        var artifact = ArtifactFor(expected);
        var download = new RecordingDownloadClient("corrupt!"u8.ToArray());
        await using var manager = CreateManager(artifact, directory.Path, download);

        var rejected = await manager.PrepareAsync(downloadDisclosureAccepted: true);
        Assert.AreEqual(ModelPreparationStatus.VerificationFailed, rejected.Status);
        Assert.IsFalse(File.Exists(Path.Combine(directory.Path, artifact.FileName)));

        download.Bytes = expected;
        var retried = await manager.PrepareAsync(downloadDisclosureAccepted: true);
        Assert.AreEqual(ModelPreparationStatus.Ready, retried.Status);
    }

    [TestMethod]
    public async Task InsufficientSpaceDoesNotStartDownload()
    {
        using var directory = new TemporaryDirectory();
        var bytes = "model"u8.ToArray();
        var artifact = ArtifactFor(bytes);
        var download = new RecordingDownloadClient(bytes);
        await using var manager = new ModelManager(
            artifact,
            directory.Path,
            download,
            new FixedDiskSpace(ModelManager.FreeSpaceReserveBytes));

        var result = await manager.PrepareAsync(downloadDisclosureAccepted: true);

        Assert.AreEqual(ModelPreparationStatus.InsufficientSpace, result.Status);
        Assert.AreEqual(0, download.CallCount);
        Assert.AreEqual(ModelManager.FreeSpaceReserveBytes, result.AvailableBytes);
        Assert.AreEqual(ModelManager.FreeSpaceReserveBytes + bytes.Length, result.RequiredBytes);
    }

    [TestMethod]
    public async Task StalePartialIsRemovedBeforeOfflineInspection()
    {
        using var directory = new TemporaryDirectory();
        var bytes = "model"u8.ToArray();
        var artifact = ArtifactFor(bytes);
        var partial = Path.Combine(directory.Path, artifact.FileName + ".partial");
        await File.WriteAllTextAsync(partial, "stale");
        var download = new RecordingDownloadClient(bytes);
        await using var manager = CreateManager(artifact, directory.Path, download);

        var result = await manager.PrepareAsync(downloadDisclosureAccepted: false);

        Assert.AreEqual(ModelPreparationStatus.DisclosureRequired, result.Status);
        Assert.IsFalse(File.Exists(partial));
        Assert.AreEqual(0, download.CallCount);
    }

    [TestMethod]
    public void ProductModelMetadataIsPinnedAndMultilingual()
    {
        ProductModel.Default.Validate();
        Assert.DoesNotContain(".en", ProductModel.Default.FileName, StringComparison.Ordinal);
        Assert.HasCount(40, ProductModel.Default.Revision);
        Assert.HasCount(64, ProductModel.Default.Sha256);
        Assert.AreEqual("huggingface.co", ProductModel.Default.DownloadUri.Host);
    }

    private static ModelManager CreateManager(
        ModelArtifact artifact,
        string directory,
        RecordingDownloadClient download) => new(
            artifact,
            directory,
            download,
            new FixedDiskSpace(long.MaxValue));

    private static ModelArtifact ArtifactFor(byte[] bytes) => new(
        Id: "test-model",
        Revision: new string('a', 40),
        FileName: "test-model.bin",
        DownloadUri: new Uri("https://models.invalid/test-model.bin"),
        SizeBytes: bytes.Length,
        Sha256: Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
        License: "test-only");

    private sealed class FixedDiskSpace(long availableBytes) : IModelDiskSpace
    {
        public long GetAvailableBytes(string directoryPath) => availableBytes;
    }

    private sealed class RecordingDownloadClient(byte[] bytes, Task? delay = null) : IModelDownloadClient
    {
        public TaskCompletionSource Opened { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public byte[] Bytes { get; set; } = bytes;

        public Task Delay { get; set; } = delay ?? Task.CompletedTask;

        public int CallCount { get; private set; }

        public async Task<Stream> OpenReadAsync(
            ModelArtifact artifact,
            CancellationToken cancellationToken)
        {
            CallCount++;
            Opened.TrySetResult();
            await Delay.WaitAsync(cancellationToken);
            return new MemoryStream(Bytes, writable: false);
        }
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "witness-model-tests",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            Directory.Delete(Path, recursive: true);
        }
    }
}
