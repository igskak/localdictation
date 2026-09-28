namespace Witness.Core.Insertion;

public enum InsertionProtectionState
{
    Ordinary,
    Protected,
    Unknown,
}

public enum InsertionPlanKind
{
    Cancel,
    Refuse,
    RetainInWitness,
    DirectSelectionWrite,
    ProtectedClipboardPaste,
    ProtectedClipboardOnly,
}

public enum InsertionPlanReason
{
    None,
    Superseded,
    DesktopUnavailable,
    ProtectedField,
    ProtectionUnknown,
    NoCapturedTarget,
    TargetChanged,
    PasteUnavailable,
    ClipboardProtectionUnavailable,
}

public sealed record InsertionContext(
    bool IsCurrentGeneration = true,
    bool DesktopAvailable = true,
    InsertionProtectionState Protection = InsertionProtectionState.Ordinary,
    bool HasCapturedTarget = true,
    bool CapturedTargetIsCurrent = true,
    bool SupportsVerifiedSelectionReplacement = true,
    bool CanSynthesizePaste = true,
    bool CanWriteProtectedClipboard = true);

public sealed record InsertionPlan(InsertionPlanKind Kind, InsertionPlanReason Reason)
{
    public static InsertionPlan Direct { get; } =
        new(InsertionPlanKind.DirectSelectionWrite, InsertionPlanReason.None);

    public static InsertionPlan Paste { get; } =
        new(InsertionPlanKind.ProtectedClipboardPaste, InsertionPlanReason.None);
}

/// <summary>
/// Chooses an insertion path from facts collected immediately before the side
/// effect. Unknown protection never degrades into an automatic copy or paste.
/// </summary>
public static class InsertionPolicy
{
    public static InsertionPlan Plan(InsertionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);

        if (!context.IsCurrentGeneration)
        {
            return new(InsertionPlanKind.Cancel, InsertionPlanReason.Superseded);
        }
        if (!context.DesktopAvailable)
        {
            return new(InsertionPlanKind.RetainInWitness, InsertionPlanReason.DesktopUnavailable);
        }
        if (context.Protection == InsertionProtectionState.Protected)
        {
            return new(InsertionPlanKind.Refuse, InsertionPlanReason.ProtectedField);
        }
        if (context.Protection == InsertionProtectionState.Unknown)
        {
            return new(InsertionPlanKind.RetainInWitness, InsertionPlanReason.ProtectionUnknown);
        }

        if (!context.HasCapturedTarget)
        {
            return ClipboardOnlyOrRetain(context, InsertionPlanReason.NoCapturedTarget);
        }
        if (!context.CapturedTargetIsCurrent)
        {
            return ClipboardOnlyOrRetain(context, InsertionPlanReason.TargetChanged);
        }
        if (context.SupportsVerifiedSelectionReplacement)
        {
            return InsertionPlan.Direct;
        }
        if (!context.CanWriteProtectedClipboard)
        {
            return new(
                InsertionPlanKind.RetainInWitness,
                InsertionPlanReason.ClipboardProtectionUnavailable);
        }
        if (!context.CanSynthesizePaste)
        {
            return new(
                InsertionPlanKind.ProtectedClipboardOnly,
                InsertionPlanReason.PasteUnavailable);
        }
        return InsertionPlan.Paste;
    }

    private static InsertionPlan ClipboardOnlyOrRetain(
        InsertionContext context,
        InsertionPlanReason clipboardReason) =>
        context.CanWriteProtectedClipboard
            ? new(InsertionPlanKind.ProtectedClipboardOnly, clipboardReason)
            : new(
                InsertionPlanKind.RetainInWitness,
                InsertionPlanReason.ClipboardProtectionUnavailable);
}

public sealed record TextFieldFingerprint(
    int? CharacterCount = null,
    int? SelectionStart = null,
    int? SelectionLength = null)
{
    public bool HasObservation => CharacterCount is not null || SelectionStart is not null;
}

public static class DirectWriteVerification
{
    public static bool DidChange(TextFieldFingerprint before, TextFieldFingerprint after)
    {
        ArgumentNullException.ThrowIfNull(before);
        ArgumentNullException.ThrowIfNull(after);
        return before.HasObservation && after.HasObservation && before != after;
    }
}

public static class PasteContentVerification
{
    public static string? ExpectedValue(
        string? valueBeforePaste,
        int selectionStart,
        int selectionLength,
        string payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        if (valueBeforePaste is null
            || selectionStart < 0
            || selectionLength < 0
            || selectionStart > valueBeforePaste.Length
            || selectionLength > valueBeforePaste.Length - selectionStart)
        {
            return null;
        }

        return string.Concat(
            valueBeforePaste.AsSpan(0, selectionStart),
            payload.AsSpan(),
            valueBeforePaste.AsSpan(selectionStart + selectionLength));
    }

    public static bool DidPasteExactly(
        string? valueBeforePaste,
        string? valueAfterPaste,
        int selectionStart,
        int selectionLength,
        string payload)
    {
        var expected = ExpectedValue(valueBeforePaste, selectionStart, selectionLength, payload);
        return expected is not null
            && string.Equals(expected, valueAfterPaste, StringComparison.Ordinal);
    }
}

public enum ClipboardAfterPasteAction
{
    RestoreSnapshot,
    LeaveDictationForRecovery,
    PreserveNewerClipboard,
}

public static class ClipboardRestorePolicy
{
    public static ClipboardAfterPasteAction Decide(
        bool exactPayloadWasVerified,
        uint? sequenceAfterWitnessWrite,
        uint? currentSequence)
    {
        if (sequenceAfterWitnessWrite is null || currentSequence is null)
        {
            return ClipboardAfterPasteAction.LeaveDictationForRecovery;
        }
        if (sequenceAfterWitnessWrite != currentSequence)
        {
            return ClipboardAfterPasteAction.PreserveNewerClipboard;
        }
        return exactPayloadWasVerified
            ? ClipboardAfterPasteAction.RestoreSnapshot
            : ClipboardAfterPasteAction.LeaveDictationForRecovery;
    }
}

public enum ModifierReleaseState
{
    Waiting,
    Released,
    TimedOut,
}

/// <summary>
/// Bounded polling state for the configured hotkey modifiers. Platform code
/// supplies each observation and performs the actual delay.
/// </summary>
public sealed class ModifierReleaseTracker
{
    private readonly int maximumPolls;
    private int completedPolls;

    public ModifierReleaseTracker(int maximumPolls)
    {
        if (maximumPolls < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumPolls));
        }
        this.maximumPolls = maximumPolls;
    }

    public ModifierReleaseState Observe(bool anyConfiguredModifierDown)
    {
        if (!anyConfiguredModifierDown)
        {
            return ModifierReleaseState.Released;
        }
        completedPolls++;
        return completedPolls >= maximumPolls
            ? ModifierReleaseState.TimedOut
            : ModifierReleaseState.Waiting;
    }
}
