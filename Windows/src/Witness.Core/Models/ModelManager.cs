using System.Buffers;
using System.Security.Cryptography;

namespace Witness.Core.Models;

public sealed class ModelManager : IAsyncDisposable
{
    public const long FreeSpaceReserveBytes = 128L * 1024 * 1024;

    private const int CopyBufferSize = 1024 * 1024;
    private readonly object sync = new();
    private readonly ModelArtifact artifact;
    private readonly string modelDirectory;
    private readonly IModelDownloadClient downloadClient;
    private readonly IModelDiskSpace diskSpace;
    private CancellationTokenSource? activeCancellation;
    private Task<ModelPreparationResult>? activeTask;
    private bool disposed;

    public ModelManager(
        ModelArtifact artifact,
        string modelDirectory,
        IModelDownloadClient downloadClient,
        IModelDiskSpace diskSpace)
    {
        artifact.Validate();
        ArgumentException.ThrowIfNullOrWhiteSpace(modelDirectory);
        this.artifact = artifact;
        this.modelDirectory = Path.GetFullPath(modelDirectory);
        this.downloadClient = downloadClient ?? throw new ArgumentNullException(nameof(downloadClient));
        this.diskSpace = diskSpace ?? throw new ArgumentNullException(nameof(diskSpace));
    }

    public event EventHandler<ModelPreparationProgress>? ProgressChanged;

    public Task<ModelPreparationResult> PrepareAsync(
        bool downloadDisclosureAccepted,
        CancellationToken cancellationToken = default)
    {
        Task<ModelPreparationResult> operation;
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (activeTask is null)
            {
                activeCancellation = new CancellationTokenSource();
                activeTask = RunAndClearAsync(downloadDisclosureAccepted, activeCancellation.Token);
            }

            operation = activeTask;
        }

        return cancellationToken.CanBeCanceled
            ? operation.WaitAsync(cancellationToken)
            : operation;
    }

    public bool CancelActive()
    {
        lock (sync)
        {
            if (activeTask is null || activeTask.IsCompleted)
            {
                return false;
            }

            activeCancellation!.Cancel();
            return true;
        }
    }

    public async ValueTask DisposeAsync()
    {
        Task<ModelPreparationResult>? operation;
        lock (sync)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            activeCancellation?.Cancel();
            operation = activeTask;
        }

        if (operation is not null)
        {
            try
            {
                await operation.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
    }

    private async Task<ModelPreparationResult> RunAndClearAsync(
        bool disclosureAccepted,
        CancellationToken cancellationToken)
    {
        // Do not let a synchronously completed inspection clear the operation
        // before PrepareAsync has published its task under the lock.
        await Task.Yield();
        try
        {
            return await PrepareCoreAsync(disclosureAccepted, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (sync)
            {
                activeCancellation?.Dispose();
                activeCancellation = null;
                activeTask = null;
            }
        }
    }

    private async Task<ModelPreparationResult> PrepareCoreAsync(
        bool disclosureAccepted,
        CancellationToken cancellationToken)
    {
        var finalPath = Path.Combine(modelDirectory, artifact.FileName);
        var partialPath = finalPath + ".partial";
        var committed = false;

        try
        {
            Report(ModelPreparationStage.Inspecting, 0);
            Directory.CreateDirectory(modelDirectory);
            DeleteIfPresent(partialPath);

            if (await IsValidAsync(finalPath, cancellationToken).ConfigureAwait(false))
            {
                Report(ModelPreparationStage.Ready, artifact.SizeBytes);
                return new ModelPreparationResult(ModelPreparationStatus.Ready, finalPath);
            }

            if (!disclosureAccepted)
            {
                Report(ModelPreparationStage.AwaitingDisclosure, 0);
                return new ModelPreparationResult(
                    ModelPreparationStatus.DisclosureRequired,
                    RequiredBytes: artifact.SizeBytes);
            }

            var requiredBytes = checked(artifact.SizeBytes + FreeSpaceReserveBytes);
            var availableBytes = diskSpace.GetAvailableBytes(modelDirectory);
            if (availableBytes < requiredBytes)
            {
                return new ModelPreparationResult(
                    ModelPreparationStatus.InsufficientSpace,
                    RequiredBytes: requiredBytes,
                    AvailableBytes: availableBytes);
            }

            DeleteIfPresent(finalPath);
            var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using var source = await downloadClient
                .OpenReadAsync(artifact, cancellationToken)
                .ConfigureAwait(false);
            await using var destination = new FileStream(
                partialPath,
                new FileStreamOptions
                {
                    Access = FileAccess.Write,
                    Mode = FileMode.CreateNew,
                    Options = FileOptions.Asynchronous | FileOptions.SequentialScan,
                    Share = FileShare.None,
                });

            var buffer = ArrayPool<byte>.Shared.Rent(CopyBufferSize);
            long completedBytes = 0;
            try
            {
                while (true)
                {
                    var read = await source
                        .ReadAsync(buffer.AsMemory(0, CopyBufferSize), cancellationToken)
                        .ConfigureAwait(false);
                    if (read == 0)
                    {
                        break;
                    }

                    completedBytes = checked(completedBytes + read);
                    if (completedBytes > artifact.SizeBytes)
                    {
                        return new ModelPreparationResult(ModelPreparationStatus.VerificationFailed);
                    }

                    hash.AppendData(buffer, 0, read);
                    await destination
                        .WriteAsync(buffer.AsMemory(0, read), cancellationToken)
                        .ConfigureAwait(false);
                    Report(ModelPreparationStage.Downloading, completedBytes);
                }

                await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer, clearArray: false);
            }

            Report(ModelPreparationStage.Verifying, completedBytes);
            var actualHash = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
            if (completedBytes != artifact.SizeBytes
                || !CryptographicOperations.FixedTimeEquals(
                    Convert.FromHexString(actualHash),
                    Convert.FromHexString(artifact.Sha256)))
            {
                return new ModelPreparationResult(ModelPreparationStatus.VerificationFailed);
            }

            destination.Close();
            File.Move(partialPath, finalPath, overwrite: true);
            committed = true;
            Report(ModelPreparationStage.Ready, artifact.SizeBytes);
            return new ModelPreparationResult(ModelPreparationStatus.Ready, finalPath);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new ModelPreparationResult(ModelPreparationStatus.Cancelled);
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or CryptographicException)
        {
            return new ModelPreparationResult(ModelPreparationStatus.Failed);
        }
        finally
        {
            if (!committed)
            {
                DeleteIfPresent(partialPath);
            }
        }
    }

    private async Task<bool> IsValidAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path) || new FileInfo(path).Length != artifact.SizeBytes)
        {
            return false;
        }

        Report(ModelPreparationStage.Verifying, 0);
        await using var stream = new FileStream(
            path,
            new FileStreamOptions
            {
                Access = FileAccess.Read,
                Mode = FileMode.Open,
                Options = FileOptions.Asynchronous | FileOptions.SequentialScan,
                Share = FileShare.Read,
            });
        var actualHash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return CryptographicOperations.FixedTimeEquals(
            actualHash,
            Convert.FromHexString(artifact.Sha256));
    }

    private void Report(ModelPreparationStage stage, long completedBytes)
    {
        ProgressChanged?.Invoke(
            this,
            new ModelPreparationProgress(stage, completedBytes, artifact.SizeBytes));
    }

    private static void DeleteIfPresent(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (DirectoryNotFoundException)
        {
        }
    }
}
