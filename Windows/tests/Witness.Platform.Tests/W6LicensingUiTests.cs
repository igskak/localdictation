using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class W6LicensingUiTests
{
    [TestMethod]
    public void ClosedBetaConfigurationAcceptsOnlyAnExactHttpsActivationContract()
    {
        var publicKey = Convert.ToBase64String(Enumerable.Range(0, 32).Select(value => (byte)value).ToArray());
        var configured = Witness.App.WindowsBetaLicenseConfiguration.FromValues(
            publicKey,
            "https://beta.example.invalid/v1/activate");

        Assert.IsTrue(configured.Authority.IsConfigured);
        Assert.IsTrue(configured.HasActivationEndpoint);
        var backend = configured.CreateBackend(out var transport);
        try
        {
            Assert.IsTrue(backend.IsConfigured);
        }
        finally
        {
            transport?.Dispose();
        }

        Assert.IsFalse(Witness.App.WindowsBetaLicenseConfiguration.FromValues(
            publicKey,
            "http://beta.example.invalid/v1/activate").HasActivationEndpoint);
        Assert.IsFalse(Witness.App.WindowsBetaLicenseConfiguration.FromValues(
            publicKey,
            "https://beta.example.invalid/v1/activate?redirect=other").HasActivationEndpoint);
        Assert.IsFalse(Witness.App.WindowsBetaLicenseConfiguration.FromValues(
            publicKey,
            "https://user@beta.example.invalid/v1/activate").HasActivationEndpoint);
        Assert.IsFalse(Witness.App.WindowsBetaLicenseConfiguration.FromValues(
            publicKey,
            "https://beta.example.invalid/v1/activate#fragment").HasActivationEndpoint);
        Assert.IsFalse(Witness.App.WindowsBetaLicenseConfiguration.FromValues(
            publicKey,
            "https://beta.example.invalid/not-activation").HasActivationEndpoint);
    }

}
