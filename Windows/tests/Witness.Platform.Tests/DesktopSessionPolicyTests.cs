using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Platform.Windows.Lifecycle;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class DesktopSessionPolicyTests
{
    [TestMethod]
    public void LockLogoffAndDesktopDisconnectStopCapture()
    {
        foreach (var reason in new[]
        {
            DesktopSessionChangePolicy.ConsoleDisconnect,
            DesktopSessionChangePolicy.RemoteDisconnect,
            DesktopSessionChangePolicy.SessionLogoff,
            DesktopSessionChangePolicy.SessionLock,
        })
        {
            Assert.IsTrue(DesktopSessionChangePolicy.ShouldStopCapture(reason), reason.ToString());
        }
    }

    [TestMethod]
    public void UnlockAndConnectDoNotCreateSpuriousStops()
    {
        foreach (var reason in new[] { 1, 3, 5, 8 })
            Assert.IsFalse(DesktopSessionChangePolicy.ShouldStopCapture(reason), reason.ToString());
    }
}
