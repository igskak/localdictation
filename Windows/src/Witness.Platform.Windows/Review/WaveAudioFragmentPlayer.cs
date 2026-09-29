using System.Buffers.Binary;
using System.IO;
using System.Media;

namespace Witness.Platform.Windows.Review;

public interface IAudioFragmentPlayer : IDisposable
{
    bool TryPlay(float[] samples, int sampleRate);
    void Stop();
}

public static class PcmWaveEncoder
{
    private const int HeaderSize = 44;

    public static byte[] EncodeMonoFloat32AsPcm16(float[] samples, int sampleRate)
    {
        ArgumentNullException.ThrowIfNull(samples);
        if (samples.Length == 0)
        {
            throw new ArgumentException("At least one sample is required.", nameof(samples));
        }
        if (sampleRate <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sampleRate));
        }

        var dataSize = checked(samples.Length * sizeof(short));
        var output = new byte[checked(HeaderSize + dataSize)];
        "RIFF"u8.CopyTo(output);
        BinaryPrimitives.WriteInt32LittleEndian(output.AsSpan(4), 36 + dataSize);
        "WAVE"u8.CopyTo(output.AsSpan(8));
        "fmt "u8.CopyTo(output.AsSpan(12));
        BinaryPrimitives.WriteInt32LittleEndian(output.AsSpan(16), 16);
        BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(20), 1);
        BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(22), 1);
        BinaryPrimitives.WriteInt32LittleEndian(output.AsSpan(24), sampleRate);
        BinaryPrimitives.WriteInt32LittleEndian(output.AsSpan(28), checked(sampleRate * sizeof(short)));
        BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(32), sizeof(short));
        BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(34), 16);
        "data"u8.CopyTo(output.AsSpan(36));
        BinaryPrimitives.WriteInt32LittleEndian(output.AsSpan(40), dataSize);

        for (var index = 0; index < samples.Length; index++)
        {
            var value = float.IsFinite(samples[index]) ? Math.Clamp(samples[index], -1F, 1F) : 0F;
            var pcm = value <= -1F
                ? short.MinValue
                : (short)Math.Round(value * short.MaxValue, MidpointRounding.AwayFromZero);
            BinaryPrimitives.WriteInt16LittleEndian(
                output.AsSpan(HeaderSize + index * sizeof(short)),
                pcm);
        }
        return output;
    }
}

/// <summary>
/// Plays a short review fragment from a RAM-only WAV stream. The encoded bytes
/// are cleared whenever playback is replaced, stopped, or disposed.
/// </summary>
public sealed class WaveAudioFragmentPlayer : IAudioFragmentPlayer
{
    private readonly object gate = new();
    private SoundPlayer? player;
    private MemoryStream? stream;
    private byte[]? encoded;
    private bool disposed;

    public bool TryPlay(float[] samples, int sampleRate)
    {
        ArgumentNullException.ThrowIfNull(samples);
        byte[] wave;
        try
        {
            wave = PcmWaveEncoder.EncodeMonoFloat32AsPcm16(samples, sampleRate);
        }
        catch (ArgumentException)
        {
            return false;
        }

        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            StopLocked();
            try
            {
                encoded = wave;
                stream = new MemoryStream(encoded, writable: false);
                player = new SoundPlayer(stream);
                player.Load();
                player.Play();
                return true;
            }
            catch (Exception error) when (error is InvalidOperationException or IOException)
            {
                StopLocked();
                return false;
            }
        }
    }

    public void Stop()
    {
        lock (gate)
        {
            if (!disposed)
            {
                StopLocked();
            }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }
            StopLocked();
            disposed = true;
        }
    }

    private void StopLocked()
    {
        try
        {
            player?.Stop();
        }
        catch (InvalidOperationException)
        {
            // The stream is still cleared below; playback failure stays local.
        }
        player?.Dispose();
        player = null;
        stream?.Dispose();
        stream = null;
        if (encoded is not null)
        {
            Array.Clear(encoded);
            encoded = null;
        }
    }
}
