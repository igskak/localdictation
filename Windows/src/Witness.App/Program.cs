using System;
using Velopack;
using Witness.Platform.Windows.Lifecycle;

namespace Witness.App;

public static class Program
{
    [STAThread]
    public static void Main(string[] arguments)
    {
        VelopackApp.Build()
            .SetAutoApplyOnStartup(false)
            .Run();

#if WITNESS_W7_HARNESS
        if (W7PreservationHarness.TryRun(arguments, out var harnessExitCode))
        {
            Environment.ExitCode = harnessExitCode;
            return;
        }
#endif

        using var instance = SingleInstanceLease.TryAcquire("Witness.Windows.Beta");
        if (!instance.IsPrimaryInstance) return;

        var application = new App();
        application.InitializeComponent();
        application.Run();
    }
}
