using System.Buffers.Binary;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Platform.Windows.Review;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class WaveAudioFragmentPlayerTests
{
    [TestMethod]
    public void EncoderProducesBoundedMonoPcm16WaveEntirelyInMemory()
    {
        var wave = PcmWaveEncoder.EncodeMonoFloat32AsPcm16(
            [-2F, -1F, -0.5F, 0F, 0.5F, 1F, 2F, float.NaN],
            16_000);

        CollectionAssert.AreEqual("RIFF"u8.ToArray(), wave[..4]);
        CollectionAssert.AreEqual("WAVE"u8.ToArray(), wave[8..12]);
        CollectionAssert.AreEqual("fmt "u8.ToArray(), wave[12..16]);
        CollectionAssert.AreEqual("data"u8.ToArray(), wave[36..40]);
        Assert.AreEqual(1, BinaryPrimitives.ReadInt16LittleEndian(wave.AsSpan(22)));
        Assert.AreEqual(16_000, BinaryPrimitives.ReadInt32LittleEndian(wave.AsSpan(24)));
        Assert.AreEqual(16, BinaryPrimitives.ReadInt16LittleEndian(wave.AsSpan(34)));
        Assert.AreEqual(16, BinaryPrimitives.ReadInt32LittleEndian(wave.AsSpan(40)));
        Assert.AreEqual(short.MinValue, Sample(wave, 0));
        Assert.AreEqual(short.MinValue, Sample(wave, 1));
        Assert.AreEqual((short)0, Sample(wave, 3));
        Assert.AreEqual(short.MaxValue, Sample(wave, 5));
        Assert.AreEqual(short.MaxValue, Sample(wave, 6));
        Assert.AreEqual((short)0, Sample(wave, 7));
    }

    [TestMethod]
    public void EncoderRejectsEmptyOrInvalidInput()
    {
        Assert.ThrowsExactly<ArgumentException>(() =>
            PcmWaveEncoder.EncodeMonoFloat32AsPcm16([], 16_000));
        Assert.ThrowsExactly<ArgumentOutOfRangeException>(() =>
            PcmWaveEncoder.EncodeMonoFloat32AsPcm16([0F], 0));
    }

    private static short Sample(byte[] wave, int index) =>
        BinaryPrimitives.ReadInt16LittleEndian(wave.AsSpan(44 + index * sizeof(short)));
}
