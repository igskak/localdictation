import CoreAudio
import Foundation

/// Something the audio route did while a recording was running.
enum InputRouteEvent: Equatable, Sendable {
    /// The system-wide default input changed.
    case defaultInputChanged
    /// The bound device now reports a different channel count or sample rate.
    /// This is what a call page opening in another app looks like from here:
    /// the built-in microphone goes from 1 channel to 3 raw array channels.
    case boundDeviceFormatChanged
    /// The bound device says it is no longer alive.
    case boundDeviceDied
    /// A device appeared or disappeared.
    case deviceListChanged
    /// No input callback arrived for longer than the watchdog allows, or the
    /// callback reported a render failure.
    case inputStalled

    /// Which event survives when a burst is collapsed into one.
    ///
    /// A Bluetooth or voice-processing switch arrives as dozens of
    /// notifications within milliseconds, and they are not equally informative:
    /// a device that died says more than a list that changed.
    var precedence: Int {
        switch self {
        case .deviceListChanged: 0
        case .boundDeviceFormatChanged: 1
        case .defaultInputChanged: 2
        case .inputStalled: 3
        case .boundDeviceDied: 4
        }
    }
}

/// What capture should do about it.
enum InputRouteAction: Equatable, Sendable {
    /// Nothing to do; the recording continues untouched.
    case keep
    /// Stop this segment, drain it into the same utterance, and open that
    /// device instead. The user sees nothing.
    case rebind(AudioDeviceID)
    /// There is no input to continue with. The utterance ends, and what was
    /// already said is still transcribed and delivered.
    case interrupt(AudioCaptureError)
}

/// The device a running segment is bound to, and the format it was built for.
struct InputBinding: Equatable, Sendable {
    var deviceID: AudioDeviceID
    var sampleRate: Double
    var channelCount: Int
}

/// What the hardware looks like at the moment an event is handled.
///
/// Read once on capture's own queue, never on the Core Audio listener thread,
/// and handed to the policy whole so the decision is a pure function of it.
struct InputRouteSnapshot: Equatable, Sendable {
    var devices: [SystemAudioInput.Device]
    var defaultInputID: AudioDeviceID?
    var boundIsAlive: Bool
    var boundSampleRate: Double?
    var boundChannelCount: Int?
}

/// Whether a route change is worth following, and where to.
///
/// Pure, so every combination of trigger and user selection is a table test
/// rather than something only a second machine and a Bluetooth headset could
/// tell us.
enum InputRoutePolicy {
    static func action(
        for event: InputRouteEvent,
        selection: AudioInputSelection,
        binding: InputBinding,
        snapshot: InputRouteSnapshot
    ) -> InputRouteAction {
        let boundIsPresent = snapshot.boundIsAlive && snapshot.devices.contains { $0.id == binding.deviceID }

        switch event {
        case .boundDeviceDied:
            return resolve(selection, snapshot: snapshot, excluding: binding.deviceID)

        case .inputStalled:
            // A device that is still there gets its unit rebuilt on the spot.
            // Re-resolving would be a chance to drift onto another microphone
            // over what is usually a transient stall.
            return boundIsPresent ? .rebind(binding.deviceID) : resolve(selection, snapshot: snapshot, excluding: binding.deviceID)

        case .defaultInputChanged:
            // Only `systemDefault` asked to follow the default. The other two
            // selections named a device, and a new default is not news to them.
            guard selection == .systemDefault else { return .keep }
            return followSelection(selection, binding: binding, snapshot: snapshot)

        case .deviceListChanged:
            // A device the user did not ask for coming back is not a reason to
            // switch mid-sentence: that is how capture would flap between two
            // microphones. The preferred device is picked up by the next
            // utterance instead.
            guard !boundIsPresent else { return .keep }
            return resolve(selection, snapshot: snapshot, excluding: binding.deviceID)

        case .boundDeviceFormatChanged:
            guard boundIsPresent else {
                return resolve(selection, snapshot: snapshot, excluding: binding.deviceID)
            }
            let rate = snapshot.boundSampleRate ?? binding.sampleRate
            let channels = snapshot.boundChannelCount ?? binding.channelCount
            guard rate != binding.sampleRate || channels != binding.channelCount else { return .keep }
            return .rebind(binding.deviceID)
        }
    }

    /// Where the selection points now, keeping the current device when it is
    /// still the answer.
    private static func followSelection(
        _ selection: AudioInputSelection,
        binding: InputBinding,
        snapshot: InputRouteSnapshot
    ) -> InputRouteAction {
        guard let resolution = SystemAudioInput.resolve(
            selection,
            among: snapshot.devices,
            defaultID: snapshot.defaultInputID
        ) else {
            return .interrupt(.noInputDevice)
        }
        return resolution.device.id == binding.deviceID ? .keep : .rebind(resolution.device.id)
    }

    /// The selection's own fallback order, minus a device that has gone.
    private static func resolve(
        _ selection: AudioInputSelection,
        snapshot: InputRouteSnapshot,
        excluding excluded: AudioDeviceID?
    ) -> InputRouteAction {
        let devices = snapshot.devices.filter { $0.id != excluded }
        guard let resolution = SystemAudioInput.resolve(
            selection,
            among: devices,
            defaultID: snapshot.defaultInputID
        ) else {
            return .interrupt(.noInputDevice)
        }
        return .rebind(resolution.device.id)
    }
}

/// How hard capture may try before it gives the sentence back to the user.
///
/// A microphone that flaps, or a unit that will not start, must not spin
/// forever: the words already said are worth more than another attempt.
struct RebindBudget: Equatable, Sendable {
    /// Attempts allowed inside one window.
    static let maximumAttempts = 4
    /// Both the attempt window and how long an absent input is tolerated.
    static let window: TimeInterval = 2

    private var attempts = 0
    private var windowStart: TimeInterval?
    private var missingSince: TimeInterval?

    init() {}

    /// Counts one rebind attempt. False once the budget for this window is gone.
    mutating func allowsAttempt(at now: TimeInterval) -> Bool {
        if let start = windowStart, now - start > Self.window {
            attempts = 0
            windowStart = nil
        }
        if windowStart == nil { windowStart = now }
        attempts += 1
        return attempts <= Self.maximumAttempts
    }

    /// True while it is still worth waiting for an input to come back. False
    /// once nothing has been resolvable for longer than the window.
    mutating func toleratesMissingInput(at now: TimeInterval) -> Bool {
        let since = missingSince ?? now
        missingSince = since
        return now - since <= Self.window
    }

    /// A segment is running again, so the next problem starts from a full budget.
    mutating func recordSuccess() {
        attempts = 0
        windowStart = nil
        missingSince = nil
    }
}
