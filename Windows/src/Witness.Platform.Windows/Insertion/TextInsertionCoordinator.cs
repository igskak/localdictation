using Witness.Core.Input;
using Witness.Core.Insertion;

namespace Witness.Platform.Windows.Insertion;

public enum TextInsertionOutcomeKind
{
    InsertedDirect,
    InsertedByPaste,
    CopiedForRecovery,
    RetainedInWitness,
    RefusedProtectedField,
    Cancelled,
    UnverifiedDirectWrite,
    UnverifiedPaste,
    ClipboardProtectionFailed,
}

public sealed record TextInsertionOutcome(
    TextInsertionOutcomeKind Kind,
    InsertionPlanReason Reason = InsertionPlanReason.None,
    bool ClipboardRestored = false);

/// <summary>
/// Coordinates W4 insertion without activating another window. Every content
/// side effect is preceded by generation, desktop, root-HWND and protected-field
/// checks. Unknown state retains text in Witness rather than guessing.
/// </summary>
public sealed class TextInsertionCoordinator(
    IInsertionTargetObserver targets,
    IInsertionFieldInspector fields,
    IDirectTextInserter direct,
    IProtectedClipboard clipboard,
    IPasteInput paste,
    IInsertionDelay delay)
{
    private static readonly TimeSpan FieldTimeout = TimeSpan.FromMilliseconds(300);
    private static readonly TimeSpan VerificationDelay = TimeSpan.FromMilliseconds(20);
    private const int MaximumVerificationAttempts = 5;

    public async Task<TextInsertionOutcome> InsertAsync(
        string text,
        InsertionTarget? capturedTarget,
        HotkeyModifiers hotkeyModifiers,
        Func<bool> isCurrentGeneration,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(text);
        ArgumentNullException.ThrowIfNull(isCurrentGeneration);
        if (!isCurrentGeneration()) return Cancelled();

        var current = targets.Observe();
        if (!current.DesktopAvailable)
            return Retained(InsertionPlanReason.DesktopUnavailable);
        if (current.Target is not InsertionTarget currentTarget)
            return Retained(InsertionPlanReason.ProtectionUnknown);

        var field = await fields.ObserveAsync(
            currentTarget,
            FieldTimeout,
            cancellationToken).ConfigureAwait(false);
        if (!isCurrentGeneration()) return Cancelled();
        var protectionOutcome = ProtectionOutcome(field.Protection);
        if (protectionOutcome is not null) return protectionOutcome;

        var sameTarget = capturedTarget is InsertionTarget captured
            && ForegroundInsertionTargetService.IsSameTarget(captured, current);
        var supportsDirect = sameTarget
            && direct.SupportsVerifiedSelectionReplacement(currentTarget);
        var plan = InsertionPolicy.Plan(new InsertionContext(
            Protection: field.Protection,
            HasCapturedTarget: capturedTarget is not null,
            CapturedTargetIsCurrent: sameTarget,
            SupportsVerifiedSelectionReplacement: supportsDirect));

        if (plan.Kind == InsertionPlanKind.DirectSelectionWrite)
        {
            var directOutcome = await TryDirectAsync(
                text,
                currentTarget,
                isCurrentGeneration,
                cancellationToken).ConfigureAwait(false);
            if (directOutcome.Kind != TextInsertionOutcomeKind.CopiedForRecovery)
                return directOutcome;
            // A capability race before the direct write made the known control
            // unavailable. No write occurred; continue through protected paste.
            field = await ObserveStillSafeAsync(
                currentTarget,
                isCurrentGeneration,
                cancellationToken).ConfigureAwait(false);
            if (field is null)
                return isCurrentGeneration() ? Retained(InsertionPlanReason.TargetChanged) : Cancelled();
            protectionOutcome = ProtectionOutcome(field.Protection);
            if (protectionOutcome is not null) return protectionOutcome;
        }

        return await TryClipboardPathAsync(
            text,
            capturedTarget,
            currentTarget,
            sameTarget,
            hotkeyModifiers,
            isCurrentGeneration,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<TextInsertionOutcome> TryDirectAsync(
        string text,
        InsertionTarget target,
        Func<bool> isCurrentGeneration,
        CancellationToken cancellationToken)
    {
        var field = await ObserveStillSafeAsync(target, isCurrentGeneration, cancellationToken)
            .ConfigureAwait(false);
        if (field is null)
            return isCurrentGeneration() ? Retained(InsertionPlanReason.TargetChanged) : Cancelled();
        var protectionOutcome = ProtectionOutcome(field.Protection);
        if (protectionOutcome is not null) return protectionOutcome;
        if (!isCurrentGeneration()) return Cancelled();

        return direct.TryInsert(target, text) switch
        {
            DirectTextInsertionResult.Verified =>
                new(TextInsertionOutcomeKind.InsertedDirect),
            DirectTextInsertionResult.Protected =>
                new(TextInsertionOutcomeKind.RefusedProtectedField, InsertionPlanReason.ProtectedField),
            DirectTextInsertionResult.UnverifiedAfterWrite =>
                new(TextInsertionOutcomeKind.UnverifiedDirectWrite),
            _ => new(TextInsertionOutcomeKind.CopiedForRecovery),
        };
    }

    private async Task<TextInsertionOutcome> TryClipboardPathAsync(
        string text,
        InsertionTarget? capturedTarget,
        InsertionTarget inspectedTarget,
        bool sameTarget,
        HotkeyModifiers hotkeyModifiers,
        Func<bool> isCurrentGeneration,
        CancellationToken cancellationToken)
    {
        if (!sameTarget || capturedTarget is null)
        {
            if (!isCurrentGeneration()) return Cancelled();
            var clipboardOnlyWrite = clipboard.TryWrite(text);
            if (!clipboardOnlyWrite.Succeeded)
                return new(TextInsertionOutcomeKind.ClipboardProtectionFailed, InsertionPlanReason.ClipboardProtectionUnavailable);
            var reason = capturedTarget is null
                ? InsertionPlanReason.NoCapturedTarget
                : InsertionPlanReason.TargetChanged;
            return new(TextInsertionOutcomeKind.CopiedForRecovery, reason);
        }

        if (!await paste.WaitForHotkeyModifiersAsync(hotkeyModifiers, cancellationToken).ConfigureAwait(false))
            return Retained(InsertionPlanReason.PasteUnavailable);
        if (!isCurrentGeneration()) return Cancelled();

        var beforePaste = await ObserveStillSafeAsync(
            inspectedTarget,
            isCurrentGeneration,
            cancellationToken).ConfigureAwait(false);
        if (beforePaste is null)
            return isCurrentGeneration() ? Retained(InsertionPlanReason.TargetChanged) : Cancelled();
        var protectionOutcome = ProtectionOutcome(beforePaste.Protection);
        if (protectionOutcome is not null) return protectionOutcome;
        if (!isCurrentGeneration()) return Cancelled();
        var write = clipboard.TryWrite(text);
        if (!write.Succeeded || write.SequenceNumber is not uint witnessSequence)
            return new(TextInsertionOutcomeKind.ClipboardProtectionFailed, InsertionPlanReason.ClipboardProtectionUnavailable);
        if (!isCurrentGeneration()) return Cancelled();
        var immediatelyBeforePaste = await ObserveStillSafeAsync(
            inspectedTarget,
            isCurrentGeneration,
            cancellationToken).ConfigureAwait(false);
        if (immediatelyBeforePaste is null)
            return isCurrentGeneration()
                ? new(TextInsertionOutcomeKind.CopiedForRecovery, InsertionPlanReason.TargetChanged)
                : Cancelled();
        protectionOutcome = ProtectionOutcome(immediatelyBeforePaste.Protection);
        if (protectionOutcome is not null)
            return new(TextInsertionOutcomeKind.CopiedForRecovery, protectionOutcome.Reason);
        beforePaste = immediatelyBeforePaste;
        if (!isCurrentGeneration()) return Cancelled();
        if (!paste.TryPasteOnce())
            return new(TextInsertionOutcomeKind.CopiedForRecovery, InsertionPlanReason.PasteUnavailable);

        var exact = await VerifyPasteAsync(
            inspectedTarget,
            beforePaste,
            text,
            isCurrentGeneration,
            cancellationToken).ConfigureAwait(false);
        if (!exact) return new(TextInsertionOutcomeKind.UnverifiedPaste);
        if (!isCurrentGeneration()) return new(TextInsertionOutcomeKind.InsertedByPaste);

        var restore = clipboard.TryRestore(write.Snapshot, witnessSequence);
        return new(
            TextInsertionOutcomeKind.InsertedByPaste,
            ClipboardRestored: restore == ClipboardSnapshotRestoreResult.Restored);
    }

    private async Task<UiAutomationFieldObservation?> ObserveStillSafeAsync(
        InsertionTarget expectedTarget,
        Func<bool> isCurrentGeneration,
        CancellationToken cancellationToken)
    {
        if (!isCurrentGeneration()) return null;
        var current = targets.Observe();
        if (!ForegroundInsertionTargetService.IsSameTarget(expectedTarget, current)) return null;
        var field = await fields.ObserveAsync(
            expectedTarget,
            FieldTimeout,
            cancellationToken).ConfigureAwait(false);
        return isCurrentGeneration() ? field : null;
    }

    private async Task<bool> VerifyPasteAsync(
        InsertionTarget target,
        UiAutomationFieldObservation before,
        string payload,
        Func<bool> isCurrentGeneration,
        CancellationToken cancellationToken)
    {
        if (before.ExpectedAfterPaste(payload) is null) return false;
        for (var attempt = 0; attempt < MaximumVerificationAttempts; attempt++)
        {
            if (!isCurrentGeneration()) return false;
            if (attempt > 0)
                await delay.DelayAsync(VerificationDelay, cancellationToken).ConfigureAwait(false);
            var current = targets.Observe();
            if (!ForegroundInsertionTargetService.IsSameTarget(target, current)) return false;
            var after = await fields.ObserveAsync(target, FieldTimeout, cancellationToken)
                .ConfigureAwait(false);
            if (before.VerifiesPaste(after, payload)) return true;
        }
        return false;
    }

    private static TextInsertionOutcome? ProtectionOutcome(InsertionProtectionState protection) => protection switch
    {
        InsertionProtectionState.Protected =>
            new(TextInsertionOutcomeKind.RefusedProtectedField, InsertionPlanReason.ProtectedField),
        InsertionProtectionState.Unknown =>
            Retained(InsertionPlanReason.ProtectionUnknown),
        _ => null,
    };

    private static TextInsertionOutcome Retained(InsertionPlanReason reason) =>
        new(TextInsertionOutcomeKind.RetainedInWitness, reason);

    private static TextInsertionOutcome Cancelled() =>
        new(TextInsertionOutcomeKind.Cancelled, InsertionPlanReason.Superseded);
}
