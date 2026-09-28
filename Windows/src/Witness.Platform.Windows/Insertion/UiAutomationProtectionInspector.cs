using System.Collections.Concurrent;
using System.Windows.Automation;
using Witness.Core.Insertion;

namespace Witness.Platform.Windows.Insertion;

public interface IUiAutomationProtectionProbe
{
    InsertionProtectionState Inspect(InsertionTarget target);
}

/// <summary>
/// Serializes UI Automation calls on one background STA. Third-party providers
/// can block indefinitely; a bounded queue and per-call timeout keep that from
/// consuming more threads or turning an unknown field into an allowed target.
/// </summary>
public sealed class UiAutomationProtectionInspector : IDisposable
{
    private readonly BlockingCollection<ProbeRequest> requests = new(
        new ConcurrentQueue<ProbeRequest>(),
        boundedCapacity: 1);
    private readonly IUiAutomationProtectionProbe probe;
    private readonly Thread worker;
    private bool disposed;

    public UiAutomationProtectionInspector()
        : this(new SystemUiAutomationProtectionProbe())
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
    }

    public UiAutomationProtectionInspector(IUiAutomationProtectionProbe probe)
    {
        this.probe = probe ?? throw new ArgumentNullException(nameof(probe));
        worker = new Thread(WorkerLoop)
        {
            IsBackground = true,
            Name = "Witness UI Automation protection probe",
        };
        if (OperatingSystem.IsWindows()) worker.SetApartmentState(ApartmentState.STA);
        worker.Start();
    }

    public async Task<InsertionProtectionState> InspectAsync(
        InsertionTarget target,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        if (timeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(timeout));
        if (disposed) return InsertionProtectionState.Unknown;

        var request = new ProbeRequest(target);
        try
        {
            if (!requests.TryAdd(request)) return InsertionProtectionState.Unknown;
        }
        catch (InvalidOperationException)
        {
            return InsertionProtectionState.Unknown;
        }

        try
        {
            return await request.Completion.Task.WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            return InsertionProtectionState.Unknown;
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        requests.CompleteAdding();
        // Never wait for a third-party UIA provider that may be hung. This is a
        // background thread and it performs no content-changing operation.
    }

    private void WorkerLoop()
    {
        foreach (var request in requests.GetConsumingEnumerable())
        {
            try
            {
                request.Completion.TrySetResult(probe.Inspect(request.Target));
            }
            catch
            {
                request.Completion.TrySetResult(InsertionProtectionState.Unknown);
            }
        }
    }

    private sealed record ProbeRequest(InsertionTarget Target)
    {
        public TaskCompletionSource<InsertionProtectionState> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}

public sealed class SystemUiAutomationProtectionProbe : IUiAutomationProtectionProbe
{
    public InsertionProtectionState Inspect(InsertionTarget target)
    {
        var focused = AutomationElement.FocusedElement;
        if (focused is null) return InsertionProtectionState.Unknown;

        var processId = focused.GetCurrentPropertyValue(
            AutomationElement.ProcessIdProperty,
            ignoreDefaultValue: true);
        if (processId is not int focusedProcessId
            || focusedProcessId < 1
            || (uint)focusedProcessId != target.ProcessId
            || !IsWithinTargetWindow(focused, target.TopLevelWindow))
        {
            return InsertionProtectionState.Unknown;
        }

        var password = focused.GetCurrentPropertyValue(
            AutomationElement.IsPasswordProperty,
            ignoreDefaultValue: true);
        return password switch
        {
            true => InsertionProtectionState.Protected,
            false => InsertionProtectionState.Ordinary,
            _ => InsertionProtectionState.Unknown,
        };
    }

    private static bool IsWithinTargetWindow(AutomationElement focused, nint targetWindow)
    {
        AutomationElement? current = focused;
        for (var depth = 0; current is not null && depth < 64; depth++)
        {
            var handle = current.GetCurrentPropertyValue(
                AutomationElement.NativeWindowHandleProperty,
                ignoreDefaultValue: true);
            if (handle is int nativeHandle
                && unchecked((uint)nativeHandle) == unchecked((uint)targetWindow.ToInt64()))
            {
                return true;
            }
            current = TreeWalker.RawViewWalker.GetParent(current);
        }
        return false;
    }
}
