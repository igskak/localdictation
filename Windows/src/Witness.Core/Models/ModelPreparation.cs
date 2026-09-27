namespace Witness.Core.Models;

public enum ModelPreparationStatus
{
    Ready,
    DisclosureRequired,
    InsufficientSpace,
    Cancelled,
    VerificationFailed,
    Failed,
}

public enum ModelPreparationStage
{
    Inspecting,
    AwaitingDisclosure,
    Downloading,
    Verifying,
    Ready,
}

public sealed record ModelPreparationProgress(
    ModelPreparationStage Stage,
    long CompletedBytes,
    long TotalBytes)
{
    public double Fraction => TotalBytes <= 0
        ? 0
        : Math.Clamp((double)CompletedBytes / TotalBytes, 0, 1);
}

public sealed record ModelPreparationResult(
    ModelPreparationStatus Status,
    string? ModelPath = null,
    long RequiredBytes = 0,
    long AvailableBytes = 0)
{
    public bool IsReady => Status == ModelPreparationStatus.Ready;
}

public interface IModelDownloadClient
{
    Task<Stream> OpenReadAsync(ModelArtifact artifact, CancellationToken cancellationToken);
}

public interface IModelDiskSpace
{
    long GetAvailableBytes(string directoryPath);
}

public sealed class SystemModelDiskSpace : IModelDiskSpace
{
    public long GetAvailableBytes(string directoryPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directoryPath);
        var fullPath = Path.GetFullPath(directoryPath);
        var root = Path.GetPathRoot(fullPath)
            ?? throw new IOException("The model directory has no filesystem root.");
        return new DriveInfo(root).AvailableFreeSpace;
    }
}
