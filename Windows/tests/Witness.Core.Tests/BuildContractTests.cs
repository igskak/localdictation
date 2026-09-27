using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core;

namespace Witness.Core.Tests;

[TestClass]
public sealed class BuildContractTests
{
    [TestMethod]
    public void BuildVersionIsValidAndBetaIdentityIsSeparate()
    {
        Assert.IsTrue(Version.TryParse(ProductMetadata.Version, out var version));
        Assert.IsNotNull(version);
        Assert.IsGreaterThan(0, ProductMetadata.Build);
        Assert.StartsWith("Witness.Windows.", ProductMetadata.WindowsAppId, StringComparison.Ordinal);
        Assert.DoesNotContain("mac", ProductMetadata.WindowsAppId, StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void MacBaselineCommitHasFullGitObjectShape()
    {
        Assert.HasCount(40, ProductMetadata.MacBaselineCommit);
        Assert.IsTrue(ProductMetadata.MacBaselineCommit.All(Uri.IsHexDigit));
    }
}
