using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class PlatformTargetTests
{
    [TestMethod]
    public void HostedRunnerIsNotPresentedAsPhysicalWindowsElevenEvidence()
    {
        Assert.Inconclusive("Requires physical Windows 11 hardware QA; hosted Windows CI is a build and adapter-test environment only.");
    }
}
