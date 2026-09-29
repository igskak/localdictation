using System.Collections.Concurrent;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Witness.Core.Insertion;

namespace Witness.Platform.Windows.Insertion;

public sealed record UiAutomationFieldObservation(
    InsertionProtectionState Protection,
    string? Value = null,
    int? SelectionStart = null,
    int? SelectionLength = null)
{
    public static UiAutomationFieldObservation Unknown { get; } =
        new(InsertionProtectionState.Unknown);

    public string? ExpectedAfterPaste(string payload) =>
        SelectionStart is int start && SelectionLength is int length
            ? PasteContentVerification.ExpectedValue(Value, start, length, payload)
            : null;

    public bool VerifiesPaste(UiAutomationFieldObservation after, string payload)
    {
        ArgumentNullException.ThrowIfNull(after);
        var expected = ExpectedAfterPaste(payload);
        return Protection == InsertionProtectionState.Ordinary
            && after.Protection == InsertionProtectionState.Ordinary
            && expected is not null
            && string.Equals(expected, after.Value, StringComparison.Ordinal);
    }
}

public interface IUiAutomationProtectionProbe
{
    UiAutomationFieldObservation Inspect(InsertionTarget target);
}

public interface IInsertionFieldInspector : IDisposable
{
    Task<UiAutomationFieldObservation> ObserveAsync(
        InsertionTarget target,
        TimeSpan timeout,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Serializes UI Automation calls on one background STA. Third-party providers
/// can block indefinitely; a bounded queue and per-call timeout keep that from
/// consuming more threads or turning an unknown field into an allowed target.
/// </summary>
public sealed class UiAutomationProtectionInspector : IInsertionFieldInspector
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
        CancellationToken cancellationToken = default) =>
        (await ObserveAsync(target, timeout, cancellationToken).ConfigureAwait(false)).Protection;

    public async Task<UiAutomationFieldObservation> ObserveAsync(
        InsertionTarget target,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        if (timeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(timeout));
        if (disposed) return UiAutomationFieldObservation.Unknown;

        var request = new ProbeRequest(target);
        try
        {
            if (!requests.TryAdd(request)) return UiAutomationFieldObservation.Unknown;
        }
        catch (InvalidOperationException)
        {
            return UiAutomationFieldObservation.Unknown;
        }

        try
        {
            return await request.Completion.Task.WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            return UiAutomationFieldObservation.Unknown;
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
                request.Completion.TrySetResult(UiAutomationFieldObservation.Unknown);
            }
        }
    }

    private sealed record ProbeRequest(InsertionTarget Target)
    {
        public TaskCompletionSource<UiAutomationFieldObservation> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}

public sealed class SystemUiAutomationProtectionProbe : IUiAutomationProtectionProbe
{
    public UiAutomationFieldObservation Inspect(InsertionTarget target)
    {
        var focused = AutomationElement.FocusedElement;
        if (focused is null) return UiAutomationFieldObservation.Unknown;

        var processId = focused.GetCurrentPropertyValue(
            AutomationElement.ProcessIdProperty,
            ignoreDefaultValue: true);
        if (processId is not int focusedProcessId
            || focusedProcessId < 1
            || (uint)focusedProcessId != target.ProcessId
            || !IsWithinTargetWindow(focused, target.TopLevelWindow))
        {
            return UiAutomationFieldObservation.Unknown;
        }

        var password = focused.GetCurrentPropertyValue(
            AutomationElement.IsPasswordProperty,
            ignoreDefaultValue: true);
        var protection = password switch
        {
            true => InsertionProtectionState.Protected,
            false => InsertionProtectionState.Ordinary,
            _ => InsertionProtectionState.Unknown,
        };
        if (protection != InsertionProtectionState.Ordinary)
            return new(protection);

        return TryReadSelection(focused, out var value, out var start, out var length)
            ? new(protection, value, start, length)
            : new(protection);
    }

    private static bool TryReadSelection(
        AutomationElement focused,
        out string? value,
        out int selectionStart,
        out int selectionLength)
    {
        value = null;
        selectionStart = 0;
        selectionLength = 0;
        if (!focused.TryGetCurrentPattern(ValuePattern.Pattern, out var valueObject)
            || valueObject is not ValuePattern valuePattern
            || valuePattern.Current.IsReadOnly
            || !focused.TryGetCurrentPattern(TextPattern.Pattern, out var textObject)
            || textObject is not TextPattern textPattern)
        {
            return false;
        }

        value = valuePattern.Current.Value;
        var selections = textPattern.GetSelection();
        if (selections.Length != 1) return false;
        var selection = selections[0];
        var prefix = textPattern.DocumentRange.Clone();
        prefix.MoveEndpointByRange(
            TextPatternRangeEndpoint.End,
            selection,
            TextPatternRangeEndpoint.Start);
        var prefixText = prefix.GetText(-1);
        var selectedText = selection.GetText(-1);
        selectionStart = prefixText.Length;
        selectionLength = selectedText.Length;
        return selectionStart <= value.Length
            && selectionLength <= value.Length - selectionStart
            && value.AsSpan(selectionStart, selectionLength).SequenceEqual(selectedText);
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
