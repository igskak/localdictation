using System.Buffers.Binary;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Platform.Windows.Licensing;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class WindowsHardwareDeviceIdentityTests
{
    private static readonly Guid HardwareUuid = Guid.Parse("00112233-4455-6677-8899-aabbccddeeff");

    [TestMethod]
    public void ReadsTheTypeOneUuidFromModernRawSmbios()
    {
        var raw = RawTable(HardwareUuid.ToByteArray(), major: 3, minor: 5);
        Assert.AreEqual(HardwareUuid.ToString("D"), RawSmbiosSystemUuid.TryRead(raw));

        var result = new WindowsHardwareDeviceIdentity(new FixedProvider(raw)).Resolve();
        Assert.IsTrue(result.IsAvailable);
        Assert.AreEqual("0710e94cf3fd45e44e1120f85b89d5e6", result.DeviceId);
        Assert.IsNull(result.Error);
    }

    [TestMethod]
    public void LegacySmbiosUsesNetworkByteOrder()
    {
        var bytes = Convert.FromHexString("00112233445566778899AABBCCDDEEFF");
        var raw = RawTable(bytes, major: 2, minor: 5);
        Assert.AreEqual(HardwareUuid.ToString("D"), RawSmbiosSystemUuid.TryRead(raw));
    }

    [TestMethod]
    [DataRow((byte)0x00)]
    [DataRow((byte)0xff)]
    public void PlaceholderHardwareUuidDoesNotBecomeASharedDevice(byte placeholder)
    {
        var raw = RawTable(Enumerable.Repeat((byte)placeholder, 16).ToArray(), major: 3, minor: 5);
        var result = new WindowsHardwareDeviceIdentity(new FixedProvider(raw)).Resolve();

        Assert.IsFalse(result.IsAvailable);
        Assert.IsNull(result.DeviceId);
        Assert.IsNotNull(result.Error);
    }

    [TestMethod]
    public void MissingOrTruncatedFirmwareFailsClosed()
    {
        Assert.IsNull(RawSmbiosSystemUuid.TryRead([]));
        Assert.IsNull(RawSmbiosSystemUuid.TryRead([0, 3, 5, 0, 200, 0, 0, 0]));
        Assert.IsFalse(new WindowsHardwareDeviceIdentity(new FixedProvider(null)).Resolve().IsAvailable);
    }

    private static byte[] RawTable(byte[] uuid, byte major, byte minor)
    {
        var typeOne = new byte[26];
        typeOne[0] = 1;
        typeOne[1] = 24;
        uuid.CopyTo(typeOne, 8);
        typeOne[24] = 0;
        typeOne[25] = 0;

        var raw = new byte[8 + typeOne.Length];
        raw[1] = major;
        raw[2] = minor;
        BinaryPrimitives.WriteUInt32LittleEndian(raw.AsSpan(4, 4), (uint)typeOne.Length);
        typeOne.CopyTo(raw, 8);
        return raw;
    }

    private sealed class FixedProvider(byte[]? value) : IRawSmbiosProvider
    {
        public byte[]? Read() => value;
    }
}
