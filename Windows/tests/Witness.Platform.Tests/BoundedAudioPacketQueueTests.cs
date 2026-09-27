using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Platform.Windows.Audio;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class BoundedAudioPacketQueueTests
{
    [TestMethod]
    public unsafe void QueueCopiesPacketBeforeNativeMemoryCanChange()
    {
        var queue = new BoundedAudioPacketQueue(packetCapacity: 2, maximumPacketBytes: 8);
        var source = new byte[] { 1, 2, 3, 4 };
        fixed (byte* pointer = source)
        {
            Assert.IsTrue(queue.TryWrite((IntPtr)pointer, source.Length, 2, AudioPacketFlags.None));
        }
        source[0] = 99;

        byte[]? consumed = null;
        Assert.IsTrue(queue.TryConsume((data, frames, flags) =>
        {
            consumed = data.ToArray();
            Assert.AreEqual(2, frames);
            Assert.AreEqual(AudioPacketFlags.None, flags);
        }));
        CollectionAssert.AreEqual(new byte[] { 1, 2, 3, 4 }, consumed);
    }

    [TestMethod]
    public void SilentPacketIsZeroFilledWithoutASourcePointer()
    {
        var queue = new BoundedAudioPacketQueue(1, 4);
        Assert.IsTrue(queue.TryWrite(IntPtr.Zero, 4, 2, AudioPacketFlags.Silent));
        queue.TryConsume((data, _, flags) =>
        {
            CollectionAssert.AreEqual(new byte[4], data.ToArray());
            Assert.AreEqual(AudioPacketFlags.Silent, flags);
        });
    }

    [TestMethod]
    public void OverflowIsBoundedAndMarksNextAcceptedPacketDiscontinuous()
    {
        var queue = new BoundedAudioPacketQueue(1, 4);
        Assert.IsTrue(queue.TryWrite(IntPtr.Zero, 4, 1, AudioPacketFlags.Silent));
        Assert.IsFalse(queue.TryWrite(IntPtr.Zero, 4, 1, AudioPacketFlags.Silent));
        Assert.AreEqual(1L, queue.DroppedPacketCount);
        Assert.IsTrue(queue.TryConsume((_, _, _) => { }));

        Assert.IsTrue(queue.TryWrite(IntPtr.Zero, 4, 1, AudioPacketFlags.Silent));
        queue.TryConsume((_, _, flags) => Assert.IsTrue(flags.HasFlag(AudioPacketFlags.Discontinuity)));
    }

    [TestMethod]
    public void OversizedAndInvalidPacketsAreRejectedWithoutAllocation()
    {
        var queue = new BoundedAudioPacketQueue(1, 4);
        Assert.IsFalse(queue.TryWrite(IntPtr.Zero, 5, 1, AudioPacketFlags.Silent));
        Assert.IsFalse(queue.TryWrite(IntPtr.Zero, 1, 1, AudioPacketFlags.None));
        Assert.AreEqual(2L, queue.DroppedPacketCount);
    }
}
