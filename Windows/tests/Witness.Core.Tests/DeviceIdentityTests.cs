using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Licensing;

namespace Witness.Core.Tests;

[TestClass]
public sealed class DeviceIdentityTests
{
    [TestMethod]
    public void SameUuidHasOneStableWindowsScopedIdentifier()
    {
        Assert.IsTrue(DeviceIdentityDerivation.TryDerive("00112233-4455-6677-8899-AABBCCDDEEFF", out var first));
        Assert.IsTrue(DeviceIdentityDerivation.TryDerive("{00112233-4455-6677-8899-aabbccddeeff}", out var second));

        Assert.AreEqual(first, second);
        Assert.AreEqual("0710e94cf3fd45e44e1120f85b89d5e6", first);
        Assert.HasCount(32, first);
        Assert.IsTrue(DeviceIdentityDerivation.IsValidDeviceId(first));
        Assert.IsTrue(first.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f'));
    }

    [TestMethod]
    public void DifferentHardwareHasADifferentIdentifier()
    {
        Assert.IsTrue(DeviceIdentityDerivation.TryDerive("00112233-4455-6677-8899-aabbccddeeff", out var first));
        Assert.IsTrue(DeviceIdentityDerivation.TryDerive("10112233-4455-6677-8899-aabbccddeeff", out var second));
        Assert.AreNotEqual(first, second);
    }

    [TestMethod]
    [DataRow(null)]
    [DataRow("")]
    [DataRow("unavailable")]
    [DataRow("00000000-0000-0000-0000-000000000000")]
    [DataRow("ffffffff-ffff-ffff-ffff-ffffffffffff")]
    public void MissingAndPlaceholderUuidsAreRefused(string? value)
    {
        Assert.IsFalse(DeviceIdentityDerivation.TryDerive(value, out var deviceId));
        Assert.AreEqual(string.Empty, deviceId);
    }

    [TestMethod]
    [DataRow("0123456789abcdef0123456789abcde")]
    [DataRow("0123456789ABCDEF0123456789ABCDEF")]
    [DataRow("0123456789abcdef0123456789abcdeg")]
    public void DeviceContractRejectsAnythingExceptLowercaseHex32(string value) =>
        Assert.IsFalse(DeviceIdentityDerivation.IsValidDeviceId(value));
}
