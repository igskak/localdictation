using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Runtime.InteropServices;
using Witness.Core.Audio;
using Witness.Platform.Windows.Audio;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class AudioCaptureSessionTests
{
    [TestMethod]
    public async Task InterruptionPreservesAnAlreadyDetectedPhrase()
    {
        using var source = new FakePacketSource();
        var processor = new FakeProcessor();
        using var session = new AudioCaptureSession(source, processor, TestConfiguration());
        session.Start();
        source.Enqueue(Enumerable.Repeat(0.1F, 3_000).ToArray());
        source.EnqueueInterruption();

        var result = await session.StopAsync();

        Assert.AreEqual(AudioCaptureCompletionKind.InterruptedWithSpeech, result.Kind);
        Assert.IsGreaterThan(0, result.Pcm16KhzMono.Length);
        Assert.AreEqual(1, processor.ResampleCalls);
    }

    [TestMethod]
    public async Task SilenceReturnsNoSpeechWithoutRunningResampler()
    {
        using var source = new FakePacketSource();
        var processor = new FakeProcessor();
        using var session = new AudioCaptureSession(source, processor, TestConfiguration());
        session.Start();
        source.Enqueue(new float[3_000]);

        var result = await session.StopAsync();

        Assert.AreEqual(AudioCaptureCompletionKind.NoSpeech, result.Kind);
        Assert.HasCount(0, result.Pcm16KhzMono);
        Assert.AreEqual(0, processor.ResampleCalls);
    }

    [TestMethod]
    public async Task DiscontinuityIsReportedAlongsideTheRecoveredPhrase()
    {
        using var source = new FakePacketSource();
        using var session = new AudioCaptureSession(source, new FakeProcessor(), TestConfiguration());
        session.Start();
        source.Enqueue(Enumerable.Repeat(0.1F, 3_000).ToArray(), AudioPacketFlags.Discontinuity);

        var result = await session.StopAsync();

        Assert.AreEqual(AudioCaptureCompletionKind.Speech, result.Kind);
        Assert.IsTrue(result.HadDiscontinuity);
    }

    [TestMethod]
    public async Task SpeechStartIsReportedForCompletedAudio()
    {
        using var source = new FakePacketSource();
        using var session = new AudioCaptureSession(source, new FakeProcessor(), TestConfiguration());
        session.Start();
        source.Enqueue(new float[2_400]);
        source.Enqueue(new float[2_400]);
        source.Enqueue(Enumerable.Repeat(0.1F, 3_000).ToArray());

        var result = await session.StopAsync();

        Assert.AreEqual(AudioCaptureCompletionKind.Speech, result.Kind);
        Assert.IsNotNull(result.SpeechStartSeconds);
        Assert.AreEqual(0.1, result.SpeechStartSeconds.Value, 0.001);
    }

    private static VoiceActivityConfiguration TestConfiguration() =>
        new(0.02, 0.02F, 0.012F, 3, 0.1, 1);

    private sealed class FakePacketSource : IAudioPacketSource
    {
        public BoundedAudioPacketQueue Queue { get; } = new(8, 16_384);
        public EventWaitHandle PacketAvailable { get; } = new AutoResetEvent(false);

        public NativeCaptureFormat Start() => new(48_000, 1, 4, NativeAudioSampleFormat.Float32LittleEndian);
        public void Stop() => PacketAvailable.Set();
        public void Dispose() => PacketAvailable.Dispose();

        public unsafe void Enqueue(float[] samples, AudioPacketFlags flags = AudioPacketFlags.None)
        {
            var bytes = MemoryMarshal.AsBytes(samples.AsSpan());
            fixed (byte* pointer = bytes)
                Assert.IsTrue(Queue.TryWrite((IntPtr)pointer, bytes.Length, samples.Length, flags));
            PacketAvailable.Set();
        }

        public void EnqueueInterruption()
        {
            Assert.IsTrue(Queue.TryWrite(IntPtr.Zero, 0, 0, AudioPacketFlags.Interrupted));
            PacketAvailable.Set();
        }
    }

    private sealed class FakeProcessor : IAudioSampleProcessor
    {
        public int ResampleCalls { get; private set; }

        public int DecodeToMono(
            ReadOnlySpan<byte> input,
            int frameCount,
            uint channelCount,
            NativeAudioSampleFormat format,
            Span<float> output)
        {
            MemoryMarshal.Cast<byte, float>(input).CopyTo(output);
            return frameCount;
        }

        public float[] ResampleTo16Khz(ReadOnlySpan<float> inputMono, uint inputSampleRate)
        {
            ResampleCalls++;
            return inputMono[..Math.Max(1, inputMono.Length / 3)].ToArray();
        }
    }
}
