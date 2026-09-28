using Witness.Core.Transcription;

namespace Witness.Platform.Windows.Transcription;

public sealed class NativeTranscriptionSessionFactory : ILocalTranscriptionSessionFactory
{
    public async Task<ILocalTranscriptionSession> CreateAsync(
        string verifiedModelPath,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(verifiedModelPath);
        var capabilities = NativeWhisperSession.ProbeBackendCapabilities();
        var required = NativeBackendCapabilities.VulkanCompiled
            | NativeBackendCapabilities.GpuDevice
            | NativeBackendCapabilities.GpuInitialized;
        var preferAccelerated = (capabilities & required) == required;
        return await TranscriptionCoordinator.CreateAsync(
            new NativeBackendFactory(verifiedModelPath),
            preferAccelerated,
            cancellationToken).ConfigureAwait(false);
    }

    private sealed class NativeBackendFactory(string modelPath) : ITranscriptionBackendFactory
    {
        public async Task<ITranscriptionBackend> CreateAsync(
            TranscriptionBackendKind kind,
            CancellationToken cancellationToken)
        {
            if (kind is not (TranscriptionBackendKind.Cpu or TranscriptionBackendKind.Vulkan))
            {
                throw new ArgumentOutOfRangeException(nameof(kind));
            }
            return await NativeWhisperSession.LoadAsync(
                modelPath,
                useGpu: kind == TranscriptionBackendKind.Vulkan,
                cancellationToken).ConfigureAwait(false);
        }
    }
}
