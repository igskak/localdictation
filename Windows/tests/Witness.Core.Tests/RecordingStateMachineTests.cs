using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Recording;

namespace Witness.Core.Tests;

[TestClass]
public sealed class RecordingStateMachineTests
{
    [TestMethod]
    public void AuthorizationMapsToState()
    {
        Assert.AreEqual(RecordingState.Ready, RecordingStateMachine.StateFor(MicrophoneAuthorization.Authorized));
        Assert.AreEqual(RecordingState.NeedsPermission, RecordingStateMachine.StateFor(MicrophoneAuthorization.NotDetermined));
        Assert.AreEqual(RecordingState.PermissionDenied(false), RecordingStateMachine.StateFor(MicrophoneAuthorization.Denied));
        Assert.AreEqual(RecordingState.PermissionDenied(true), RecordingStateMachine.StateFor(MicrophoneAuthorization.Restricted));
    }

    [TestMethod]
    public void HappyPathPressAndRelease()
    {
        var machine = new RecordingStateMachine();
        Assert.IsTrue(machine.Apply(RecordingEvent.AuthorizationResolved(MicrophoneAuthorization.Authorized)).DidTransition);
        Assert.AreEqual(RecordingState.Ready, machine.State);
        Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.HotkeyPressed)).DidTransition);
        Assert.AreEqual(RecordingState.Starting, machine.State);
        Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.CaptureStarted)).DidTransition);
        Assert.AreEqual(RecordingState.Recording, machine.State);
        Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.HotkeyReleased)).DidTransition);
        Assert.AreEqual(RecordingState.Finishing, machine.State);
        Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.UtteranceCompleted)).DidTransition);
        Assert.AreEqual(RecordingState.Ready, machine.State);
    }

    [TestMethod]
    public void ReleaseBeforeCaptureStartedRejectsLateCaptureStarted()
    {
        var machine = new RecordingStateMachine(RecordingState.Ready);
        machine.Apply(RecordingEvent.Of(RecordingEventKind.HotkeyPressed));
        Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.HotkeyReleased)).DidTransition);
        Assert.IsFalse(machine.Apply(RecordingEvent.Of(RecordingEventKind.CaptureStarted)).DidTransition);
        Assert.AreEqual(RecordingState.Finishing, machine.State);
    }

    [TestMethod]
    public void FailuresAreRecoverable()
    {
        var failure = new RecordingFailure(RecordingFailureKind.CaptureStart, "engine");
        var machine = new RecordingStateMachine(RecordingState.Ready);
        machine.Apply(RecordingEvent.Of(RecordingEventKind.HotkeyPressed));
        machine.Apply(RecordingEvent.CaptureFailed(failure));
        Assert.AreEqual(RecordingState.Failed(failure), machine.State);
        Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.RecoveryRequested)).DidTransition);
        Assert.AreEqual(RecordingState.Ready, machine.State);
    }

    [TestMethod]
    public void RevokedAuthorizationInterruptsCaptureButNotTranscriptionOrInsertion()
    {
        var recording = new RecordingStateMachine(RecordingState.Recording);
        Assert.IsTrue(recording.Apply(RecordingEvent.AuthorizationResolved(MicrophoneAuthorization.Denied)).DidTransition);
        Assert.AreEqual(RecordingFailureKind.CaptureInterrupted, recording.State.Failure?.Kind);

        foreach (var state in new[] { RecordingState.Transcribing, RecordingState.Inserting })
        {
            var machine = new RecordingStateMachine(state);
            Assert.IsFalse(machine.Apply(RecordingEvent.AuthorizationResolved(MicrophoneAuthorization.Denied)).DidTransition);
            Assert.AreEqual(state, machine.State);
        }
    }

    [TestMethod]
    public void NewRecordingSupersedesTranscriptionAndInsertion()
    {
        foreach (var state in new[] { RecordingState.Transcribing, RecordingState.Inserting })
        {
            var machine = new RecordingStateMachine(state);
            Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.HotkeyPressed)).DidTransition);
            Assert.AreEqual(RecordingState.Starting, machine.State);
        }
    }

    [TestMethod]
    public void EntitlementExpiryDuringBusyWorkIsRememberedButDoesNotDropWords()
    {
        foreach (var state in new[] { RecordingState.Starting, RecordingState.Recording, RecordingState.Finishing, RecordingState.Transcribing, RecordingState.Inserting })
        {
            var machine = new RecordingStateMachine(state);
            var transition = machine.Apply(RecordingEvent.EntitlementResolved(EntitlementLock.ActivationRequired, MicrophoneAuthorization.Authorized));
            Assert.IsFalse(transition.DidTransition, $"{state.Kind} should finish its in-flight words");
            Assert.AreEqual(state, machine.State);
            Assert.AreEqual(EntitlementLock.ActivationRequired, machine.Lock);
        }
    }

    [TestMethod]
    public void BusyWorkSettlesToRememberedLockAndNextPressCannotOpenMicrophone()
    {
        var machine = new RecordingStateMachine(RecordingState.Transcribing);
        machine.Apply(RecordingEvent.EntitlementResolved(EntitlementLock.ActivationRequired, MicrophoneAuthorization.Authorized));
        Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.TranscriptionFinished)).DidTransition);
        Assert.AreEqual(RecordingState.Locked(EntitlementLock.ActivationRequired), machine.State);
        Assert.IsTrue(machine.Apply(RecordingEvent.Of(RecordingEventKind.HotkeyPressed)).DidTransition);
        Assert.AreEqual(RecordingState.Locked(EntitlementLock.ActivationRequired), machine.State);
    }

    [TestMethod]
    public void UnrelatedAndDuplicateEventsAreRejected()
    {
        var machine = new RecordingStateMachine(RecordingState.Ready);
        foreach (var kind in new[] { RecordingEventKind.UtteranceCompleted, RecordingEventKind.CaptureStarted, RecordingEventKind.MaximumDurationReached, RecordingEventKind.InsertionFinished, RecordingEventKind.TranscriptionFinished })
        {
            Assert.IsFalse(machine.Apply(RecordingEvent.Of(kind)).DidTransition, kind.ToString());
        }
        Assert.AreEqual(RecordingState.Ready, machine.State);
    }

    [TestMethod]
    public void GenerationRejectsLateCallbacksFromSupersededDictation()
    {
        var generations = new OperationGeneration();
        var first = generations.Supersede();
        var second = generations.Supersede();
        Assert.IsFalse(generations.IsCurrent(first));
        Assert.IsTrue(generations.IsCurrent(second));
    }
}
