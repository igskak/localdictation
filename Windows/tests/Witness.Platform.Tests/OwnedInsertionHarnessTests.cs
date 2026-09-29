using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Windows.Automation;
using System.Windows.Threading;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class OwnedInsertionHarnessTests
{
    [TestMethod]
    public void HarnessProvidesAccessibleNormalPasswordAndDelayedPasteTargets()
    {
        Exception? failure = null;
        var completed = new ManualResetEventSlim(false);
        var thread = new Thread(() =>
        {
            try
            {
                var harness = new OwnedInsertionHarness();
                Assert.AreEqual("Owned normal text field", AutomationProperties.GetName(harness.NormalText));
                Assert.AreEqual("Owned protected password field", AutomationProperties.GetName(harness.PasswordText));
                Assert.AreEqual("Owned delayed paste text field", AutomationProperties.GetName(harness.DelayedText));
                Assert.AreEqual(0, harness.NormalText.TabIndex);
                Assert.AreEqual(1, harness.PasswordText.TabIndex);
                Assert.AreEqual(2, harness.DelayedText.TabIndex);

                harness.DelayedText.PasteDelay = TimeSpan.FromMilliseconds(1);
                harness.DelayedText.Select(8, 3);
                var paste = harness.DelayedText.ApplySyntheticPasteAsync("new words");
                PumpUntil(paste);
                Assert.AreEqual("delayed new words", harness.DelayedText.Text);
                Assert.IsTrue(paste.IsCompletedSuccessfully);
            }
            catch (Exception error)
            {
                failure = error;
            }
            finally
            {
                completed.Set();
            }
        })
        {
            IsBackground = true,
            Name = "Witness owned insertion harness test",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        Assert.IsTrue(completed.Wait(TimeSpan.FromSeconds(15)), "The owned WPF harness did not complete.");
        if (failure is not null) throw new AssertFailedException("The owned WPF harness failed.", failure);
    }

    private static void PumpUntil(Task task)
    {
        var frame = new DispatcherFrame();
        var dispatcher = Dispatcher.CurrentDispatcher;
        task.ContinueWith(
            _ => dispatcher.BeginInvoke(() => frame.Continue = false),
            CancellationToken.None,
            TaskContinuationOptions.None,
            TaskScheduler.Default);
        Dispatcher.PushFrame(frame);
    }
}
