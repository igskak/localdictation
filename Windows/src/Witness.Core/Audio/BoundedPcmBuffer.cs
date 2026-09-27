namespace Witness.Core.Audio;

public readonly record struct BufferAppendResult(int AcceptedFrames, int DroppedFrames);

public sealed class BoundedPcmBuffer
{
    private readonly float[] _storage;

    public BoundedPcmBuffer(int capacityFrames)
    {
        if (capacityFrames <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(capacityFrames));
        }
        _storage = new float[capacityFrames];
    }

    public int CapacityFrames => _storage.Length;
    public int FrameCount { get; private set; }
    public long DroppedFrameCount { get; private set; }
    public float PeakLevel { get; private set; }
    public bool IsFull => FrameCount >= CapacityFrames;
    public int RemainingFrames => CapacityFrames - FrameCount;

    public BufferAppendResult Append(ReadOnlySpan<float> frames)
    {
        var accepted = Math.Min(RemainingFrames, frames.Length);
        if (accepted > 0)
        {
            frames[..accepted].CopyTo(_storage.AsSpan(FrameCount));
            for (var index = 0; index < accepted; index++)
            {
                PeakLevel = Math.Max(PeakLevel, Math.Abs(frames[index]));
            }
            FrameCount += accepted;
        }

        var dropped = frames.Length - accepted;
        DroppedFrameCount += dropped;
        return new BufferAppendResult(accepted, dropped);
    }

    public ReadOnlySpan<float> Samples => _storage.AsSpan(0, FrameCount);

    public float[] MakeSamples() => Samples.ToArray();

    public void Reset()
    {
        FrameCount = 0;
        DroppedFrameCount = 0;
        PeakLevel = 0;
    }
}
