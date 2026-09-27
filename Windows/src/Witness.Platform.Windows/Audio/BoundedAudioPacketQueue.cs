using System.Threading;

namespace Witness.Platform.Windows.Audio;

[Flags]
public enum AudioPacketFlags : uint
{
    None = 0,
    Silent = 1,
    Discontinuity = 2,
    Interrupted = 4,
}

public delegate void AudioPacketConsumer(ReadOnlySpan<byte> data, int frameCount, AudioPacketFlags flags);

/// <summary>A preallocated single-producer/single-consumer queue for the native capture callback.</summary>
public sealed class BoundedAudioPacketQueue
{
    private readonly Slot[] slots;
    private readonly int usableCapacity;
    private int readIndex;
    private int writeIndex;
    private int pendingDiscontinuity;
    private long droppedPacketCount;

    public BoundedAudioPacketQueue(int packetCapacity, int maximumPacketBytes)
    {
        if (packetCapacity < 1) throw new ArgumentOutOfRangeException(nameof(packetCapacity));
        if (maximumPacketBytes < 1) throw new ArgumentOutOfRangeException(nameof(maximumPacketBytes));
        usableCapacity = packetCapacity;
        slots = Enumerable.Range(0, packetCapacity + 1)
            .Select(_ => new Slot(maximumPacketBytes))
            .ToArray();
    }

    public int Capacity => usableCapacity;
    public int MaximumPacketBytes => slots[0].Buffer.Length;
    public long DroppedPacketCount => Interlocked.Read(ref droppedPacketCount);

    public unsafe bool TryWrite(IntPtr source, int sizeBytes, int frameCount, AudioPacketFlags flags)
    {
        if (sizeBytes < 0 || sizeBytes > MaximumPacketBytes || frameCount < 0 ||
            (source == IntPtr.Zero && sizeBytes > 0 && (flags & AudioPacketFlags.Silent) == 0))
        {
            MarkDropped();
            return false;
        }

        var write = Volatile.Read(ref writeIndex);
        var next = (write + 1) % slots.Length;
        if (next == Volatile.Read(ref readIndex))
        {
            MarkDropped();
            return false;
        }

        var slot = slots[write];
        if (sizeBytes > 0)
        {
            if (source == IntPtr.Zero)
            {
                slot.Buffer.AsSpan(0, sizeBytes).Clear();
            }
            else
            {
                new ReadOnlySpan<byte>(source.ToPointer(), sizeBytes).CopyTo(slot.Buffer);
            }
        }
        slot.SizeBytes = sizeBytes;
        slot.FrameCount = frameCount;
        slot.Flags = flags;
        if (Interlocked.Exchange(ref pendingDiscontinuity, 0) != 0)
            slot.Flags |= AudioPacketFlags.Discontinuity;
        Volatile.Write(ref writeIndex, next);
        return true;
    }

    public bool TryConsume(AudioPacketConsumer consumer)
    {
        ArgumentNullException.ThrowIfNull(consumer);
        var read = Volatile.Read(ref readIndex);
        if (read == Volatile.Read(ref writeIndex)) return false;
        var slot = slots[read];
        try
        {
            consumer(slot.Buffer.AsSpan(0, slot.SizeBytes), slot.FrameCount, slot.Flags);
        }
        finally
        {
            Volatile.Write(ref readIndex, (read + 1) % slots.Length);
        }
        return true;
    }

    private void MarkDropped()
    {
        Interlocked.Increment(ref droppedPacketCount);
        Interlocked.Exchange(ref pendingDiscontinuity, 1);
    }

    private sealed class Slot(int size)
    {
        public byte[] Buffer { get; } = new byte[size];
        public int SizeBytes { get; set; }
        public int FrameCount { get; set; }
        public AudioPacketFlags Flags { get; set; }
    }
}
