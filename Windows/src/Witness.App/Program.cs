using System;
using Velopack;
using Witness.Platform.Windows.Lifecycle;

namespace Witness.App;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        VelopackApp.Build()
            .SetAutoApplyOnStartup(false)
            .Run();

        using var instance = SingleInstanceLease.TryAcquire("Witness.Windows.Beta");
        if (!instance.IsPrimaryInstance) return;

        var application = new App();
        application.InitializeComponent();
        application.Run();
    }
}
