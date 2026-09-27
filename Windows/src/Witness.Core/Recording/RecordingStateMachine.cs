namespace Witness.Core.Recording;

public enum MicrophoneAuthorization
{
    NotDetermined,
    Authorized,
    Denied,
    Restricted,
}

public enum RecordingFailureKind
{
    HotkeyRegistration,
    CaptureStart,
    CaptureInterrupted,
    Transcription,
}

public sealed record RecordingFailure(RecordingFailureKind Kind, string Detail);

public enum EntitlementLockKind
{
    ActivationRequired,
    ExpiredTrial,
    ExpiredAnnual,
    UpdateRequired,
}

public sealed record EntitlementLock(
    EntitlementLockKind Kind,
    DateTimeOffset? ExpiredAt = null,
    int? CoveredMajor = null,
    int? RunningMajor = null)
{
    public static EntitlementLock ActivationRequired { get; } = new(EntitlementLockKind.ActivationRequired);
}

public enum RecordingStateKind
{
    Launching,
    NeedsPermission,
    RequestingPermission,
    PermissionDenied,
    Ready,
    Starting,
    Recording,
    Finishing,
    Transcribing,
    Inserting,
    Locked,
    Failed,
}

public sealed record RecordingState(
    RecordingStateKind Kind,
    bool Restricted = false,
    EntitlementLock? Lock = null,
    RecordingFailure? Failure = null)
{
    public bool IsCapturing => Kind is RecordingStateKind.Starting or RecordingStateKind.Recording or RecordingStateKind.Finishing;
    public bool IsTranscribing => Kind == RecordingStateKind.Transcribing;
    public bool IsInserting => Kind == RecordingStateKind.Inserting;
    public bool IsBusy => IsCapturing || IsTranscribing || IsInserting;

    public static RecordingState Launching { get; } = new(RecordingStateKind.Launching);
    public static RecordingState NeedsPermission { get; } = new(RecordingStateKind.NeedsPermission);
    public static RecordingState RequestingPermission { get; } = new(RecordingStateKind.RequestingPermission);
    public static RecordingState Ready { get; } = new(RecordingStateKind.Ready);
    public static RecordingState Starting { get; } = new(RecordingStateKind.Starting);
    public static RecordingState Recording { get; } = new(RecordingStateKind.Recording);
    public static RecordingState Finishing { get; } = new(RecordingStateKind.Finishing);
    public static RecordingState Transcribing { get; } = new(RecordingStateKind.Transcribing);
    public static RecordingState Inserting { get; } = new(RecordingStateKind.Inserting);
    public static RecordingState PermissionDenied(bool restricted) => new(RecordingStateKind.PermissionDenied, Restricted: restricted);
    public static RecordingState Locked(EntitlementLock value) => new(RecordingStateKind.Locked, Lock: value);
    public static RecordingState Failed(RecordingFailure value) => new(RecordingStateKind.Failed, Failure: value);
}

public enum RecordingEventKind
{
    AuthorizationResolved,
    PermissionRequestStarted,
    HotkeyPressed,
    HotkeyReleased,
    CaptureStarted,
    CaptureFailed,
    CaptureInterrupted,
    MaximumDurationReached,
    UtteranceCompleted,
    TranscriptionStarted,
    TranscriptionFinished,
    TranscriptionFailed,
    InsertionStarted,
    InsertionFinished,
    EntitlementResolved,
    HotkeyRegistrationFailed,
    RecoveryRequested,
}

public sealed record RecordingEvent(
    RecordingEventKind Kind,
    MicrophoneAuthorization Authorization = MicrophoneAuthorization.NotDetermined,
    RecordingFailure? Failure = null,
    EntitlementLock? Lock = null,
    string? Detail = null)
{
    public static RecordingEvent AuthorizationResolved(MicrophoneAuthorization value) => new(RecordingEventKind.AuthorizationResolved, Authorization: value);
    public static RecordingEvent EntitlementResolved(EntitlementLock? value, MicrophoneAuthorization authorization) => new(RecordingEventKind.EntitlementResolved, authorization, Lock: value);
    public static RecordingEvent CaptureFailed(RecordingFailure value) => new(RecordingEventKind.CaptureFailed, Failure: value);
    public static RecordingEvent CaptureInterrupted(RecordingFailure value) => new(RecordingEventKind.CaptureInterrupted, Failure: value);
    public static RecordingEvent TranscriptionFailed(string detail) => new(RecordingEventKind.TranscriptionFailed, Detail: detail);
    public static RecordingEvent HotkeyRegistrationFailed(string detail) => new(RecordingEventKind.HotkeyRegistrationFailed, Detail: detail);
    public static RecordingEvent Of(RecordingEventKind kind) => new(kind);
}

public sealed record StateTransition(bool DidTransition, RecordingState From, RecordingState To, RecordingEvent Event);

public sealed class RecordingStateMachine
{
    public RecordingStateMachine(RecordingState? state = null, EntitlementLock? entitlementLock = null)
    {
        State = state ?? RecordingState.Launching;
        Lock = entitlementLock;
    }

    public RecordingState State { get; private set; }
    public EntitlementLock? Lock { get; private set; }

    public static RecordingState StateFor(MicrophoneAuthorization authorization) => authorization switch
    {
        MicrophoneAuthorization.Authorized => RecordingState.Ready,
        MicrophoneAuthorization.NotDetermined => RecordingState.NeedsPermission,
        MicrophoneAuthorization.Denied => RecordingState.PermissionDenied(false),
        MicrophoneAuthorization.Restricted => RecordingState.PermissionDenied(true),
        _ => throw new ArgumentOutOfRangeException(nameof(authorization)),
    };

    public StateTransition Apply(RecordingEvent @event)
    {
        ArgumentNullException.ThrowIfNull(@event);
        if (@event.Kind == RecordingEventKind.EntitlementResolved)
        {
            Lock = @event.Lock;
        }

        var previous = State;
        var next = NextState(previous, @event);
        if (next is null)
        {
            return new StateTransition(false, previous, previous, @event);
        }

        State = next;
        return new StateTransition(true, previous, next, @event);
    }

    private RecordingState RestingState => Lock is null ? RecordingState.Ready : RecordingState.Locked(Lock);

    private RecordingState? NextState(RecordingState state, RecordingEvent @event)
    {
        if (@event.Kind == RecordingEventKind.EntitlementResolved)
        {
            if (state.IsBusy)
            {
                return null;
            }
            if (@event.Lock is not null)
            {
                return RecordingState.Locked(@event.Lock);
            }
            if (state.Kind == RecordingStateKind.Failed)
            {
                return null;
            }
            return StateFor(@event.Authorization);
        }

        if (@event.Kind == RecordingEventKind.AuthorizationResolved)
        {
            if (Lock is not null)
            {
                return null;
            }
            if (state.IsCapturing)
            {
                return @event.Authorization == MicrophoneAuthorization.Authorized
                    ? null
                    : RecordingState.Failed(new RecordingFailure(RecordingFailureKind.CaptureInterrupted, "Microphone access was revoked"));
            }
            if (state.IsTranscribing || state.IsInserting)
            {
                return null;
            }
            return StateFor(@event.Authorization);
        }

        if (@event.Kind == RecordingEventKind.HotkeyRegistrationFailed)
        {
            return state.IsBusy || Lock is not null
                ? null
                : RecordingState.Failed(new RecordingFailure(RecordingFailureKind.HotkeyRegistration, @event.Detail ?? string.Empty));
        }

        if (@event.Kind == RecordingEventKind.HotkeyPressed && Lock is not null)
        {
            return state.IsBusy ? null : RecordingState.Locked(Lock);
        }

        return (state.Kind, @event.Kind) switch
        {
            (RecordingStateKind.NeedsPermission, RecordingEventKind.PermissionRequestStarted) => RecordingState.RequestingPermission,
            (RecordingStateKind.Ready, RecordingEventKind.HotkeyPressed) => RecordingState.Starting,
            (RecordingStateKind.Starting, RecordingEventKind.CaptureStarted) => RecordingState.Recording,
            (RecordingStateKind.Starting, RecordingEventKind.HotkeyReleased) => RecordingState.Finishing,
            (RecordingStateKind.Starting, RecordingEventKind.CaptureFailed) => RecordingState.Failed(RequiredFailure(@event)),
            (RecordingStateKind.Starting, RecordingEventKind.CaptureInterrupted) => RecordingState.Failed(RequiredFailure(@event)),
            (RecordingStateKind.Recording, RecordingEventKind.HotkeyReleased) => RecordingState.Finishing,
            (RecordingStateKind.Recording, RecordingEventKind.MaximumDurationReached) => RecordingState.Finishing,
            (RecordingStateKind.Recording, RecordingEventKind.CaptureInterrupted) => RecordingState.Failed(RequiredFailure(@event)),
            (RecordingStateKind.Finishing, RecordingEventKind.UtteranceCompleted) => RestingState,
            (RecordingStateKind.Finishing, RecordingEventKind.CaptureInterrupted) => RecordingState.Failed(RequiredFailure(@event)),
            (RecordingStateKind.Finishing, RecordingEventKind.CaptureFailed) => RecordingState.Failed(RequiredFailure(@event)),
            (RecordingStateKind.Ready, RecordingEventKind.TranscriptionStarted) => RecordingState.Transcribing,
            (RecordingStateKind.Transcribing, RecordingEventKind.TranscriptionFinished) => RestingState,
            (RecordingStateKind.Transcribing, RecordingEventKind.TranscriptionFailed) => RecordingState.Failed(new RecordingFailure(RecordingFailureKind.Transcription, @event.Detail ?? string.Empty)),
            (RecordingStateKind.Transcribing, RecordingEventKind.HotkeyPressed) => RecordingState.Starting,
            (RecordingStateKind.Transcribing, RecordingEventKind.InsertionStarted) => RecordingState.Inserting,
            (RecordingStateKind.Ready, RecordingEventKind.InsertionStarted) => RecordingState.Inserting,
            (RecordingStateKind.Inserting, RecordingEventKind.InsertionFinished) => RestingState,
            (RecordingStateKind.Inserting, RecordingEventKind.HotkeyPressed) => RecordingState.Starting,
            (RecordingStateKind.Failed, RecordingEventKind.RecoveryRequested) => RestingState,
            _ => null,
        };
    }

    private static RecordingFailure RequiredFailure(RecordingEvent @event) =>
        @event.Failure ?? throw new ArgumentException("A failure event must carry its failure.", nameof(@event));
}
