using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Insertion;

namespace Witness.Core.Tests;

[TestClass]
public sealed class InsertionPolicyTests
{
    [TestMethod]
    public void KnownSelectionReplacementUsesDirectPathWithoutClipboard()
    {
        Assert.AreEqual(InsertionPlan.Direct, InsertionPolicy.Plan(new InsertionContext(
            CanSynthesizePaste: false,
            CanWriteProtectedClipboard: false)));
    }

    [TestMethod]
    public void OrdinaryCurrentTargetWithoutDirectSemanticsUsesProtectedPaste()
    {
        Assert.AreEqual(InsertionPlan.Paste, InsertionPolicy.Plan(new InsertionContext(
            SupportsVerifiedSelectionReplacement: false)));
    }

    [TestMethod]
    public void ProtectedAndUnknownFieldsNeverReachClipboard()
    {
        var protectedPlan = InsertionPolicy.Plan(new InsertionContext(
            Protection: InsertionProtectionState.Protected));
        var unknownPlan = InsertionPolicy.Plan(new InsertionContext(
            Protection: InsertionProtectionState.Unknown));

        Assert.AreEqual(InsertionPlanKind.Refuse, protectedPlan.Kind);
        Assert.AreEqual(InsertionPlanReason.ProtectedField, protectedPlan.Reason);
        Assert.AreEqual(InsertionPlanKind.RetainInWitness, unknownPlan.Kind);
        Assert.AreEqual(InsertionPlanReason.ProtectionUnknown, unknownPlan.Reason);
    }

    [TestMethod]
    public void LockedDesktopAndSupersededGenerationHaveNoSideEffect()
    {
        Assert.AreEqual(
            new InsertionPlan(InsertionPlanKind.RetainInWitness, InsertionPlanReason.DesktopUnavailable),
            InsertionPolicy.Plan(new InsertionContext(DesktopAvailable: false)));
        Assert.AreEqual(
            new InsertionPlan(InsertionPlanKind.Cancel, InsertionPlanReason.Superseded),
            InsertionPolicy.Plan(new InsertionContext(IsCurrentGeneration: false)));
    }

    [TestMethod]
    public void ChangedTopLevelWindowUsesOnlyProtectedClipboardFallback()
    {
        Assert.AreEqual(
            new InsertionPlan(InsertionPlanKind.ProtectedClipboardOnly, InsertionPlanReason.TargetChanged),
            InsertionPolicy.Plan(new InsertionContext(CapturedTargetIsCurrent: false)));
    }

    [TestMethod]
    public void ClipboardProtectionFailureClosesEveryClipboardPath()
    {
        var paste = InsertionPolicy.Plan(new InsertionContext(
            SupportsVerifiedSelectionReplacement: false,
            CanWriteProtectedClipboard: false));
        var changedTarget = InsertionPolicy.Plan(new InsertionContext(
            CapturedTargetIsCurrent: false,
            CanWriteProtectedClipboard: false));

        Assert.AreEqual(InsertionPlanKind.RetainInWitness, paste.Kind);
        Assert.AreEqual(InsertionPlanReason.ClipboardProtectionUnavailable, paste.Reason);
        Assert.AreEqual(InsertionPlanKind.RetainInWitness, changedTarget.Kind);
        Assert.AreEqual(InsertionPlanReason.ClipboardProtectionUnavailable, changedTarget.Reason);
    }

    [TestMethod]
    public void UipiOrInputFailureLeavesRecoverableProtectedClipboard()
    {
        Assert.AreEqual(
            new InsertionPlan(InsertionPlanKind.ProtectedClipboardOnly, InsertionPlanReason.PasteUnavailable),
            InsertionPolicy.Plan(new InsertionContext(
                SupportsVerifiedSelectionReplacement: false,
                CanSynthesizePaste: false)));
    }

    [TestMethod]
    public void ExactPasteVerificationUsesTheCapturedSelection()
    {
        Assert.AreEqual(
            "draft new words",
            PasteContentVerification.ExpectedValue("draft old", 6, 3, "new words"));
        Assert.IsTrue(PasteContentVerification.DidPasteExactly(
            "draft old", "draft new words", 6, 3, "new words"));
        Assert.IsFalse(PasteContentVerification.DidPasteExactly(
            "draft old", "draft something else", 6, 3, "new words"));
        Assert.IsNull(PasteContentVerification.ExpectedValue("short", 4, 2, "new"));
    }

    [TestMethod]
    public void CaretMovementAloneDoesNotVerifyPasteContent()
    {
        Assert.IsFalse(PasteContentVerification.DidPasteExactly(
            valueBeforePaste: null,
            valueAfterPaste: null,
            selectionStart: 4,
            selectionLength: 0,
            payload: "new"));
    }

    [TestMethod]
    public void ClipboardRestoresOnlyAfterExactPasteAndNoExternalChange()
    {
        Assert.AreEqual(
            ClipboardAfterPasteAction.RestoreSnapshot,
            ClipboardRestorePolicy.Decide(true, 42, 42));
        Assert.AreEqual(
            ClipboardAfterPasteAction.LeaveDictationForRecovery,
            ClipboardRestorePolicy.Decide(false, 42, 42));
        Assert.AreEqual(
            ClipboardAfterPasteAction.PreserveNewerClipboard,
            ClipboardRestorePolicy.Decide(true, 42, 43));
        Assert.AreEqual(
            ClipboardAfterPasteAction.LeaveDictationForRecovery,
            ClipboardRestorePolicy.Decide(true, null, 42));
    }

    [TestMethod]
    public void DirectWriteRequiresAnObservableChange()
    {
        var before = new TextFieldFingerprint(10, 4, 3);
        Assert.IsFalse(DirectWriteVerification.DidChange(before, before));
        Assert.IsTrue(DirectWriteVerification.DidChange(
            before,
            new TextFieldFingerprint(12, 6, 0)));
        Assert.IsFalse(DirectWriteVerification.DidChange(
            new TextFieldFingerprint(),
            new TextFieldFingerprint()));
    }

    [TestMethod]
    public void ModifierWaitHandlesReleaseAndTimeoutWithoutASecondPaste()
    {
        var released = new ModifierReleaseTracker(maximumPolls: 3);
        Assert.AreEqual(ModifierReleaseState.Waiting, released.Observe(anyConfiguredModifierDown: true));
        Assert.AreEqual(ModifierReleaseState.Released, released.Observe(anyConfiguredModifierDown: false));

        var timedOut = new ModifierReleaseTracker(maximumPolls: 2);
        Assert.AreEqual(ModifierReleaseState.Waiting, timedOut.Observe(anyConfiguredModifierDown: true));
        Assert.AreEqual(ModifierReleaseState.TimedOut, timedOut.Observe(anyConfiguredModifierDown: true));
    }
}
