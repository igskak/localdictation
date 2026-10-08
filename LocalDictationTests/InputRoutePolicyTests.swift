import CoreAudio
import XCTest
@testable import Witness

/// What capture does when the route moves under a sentence that is still being
/// said.
///
/// The rule the whole slice exists for: a route change continues the utterance.
/// Only an input that cannot be resolved at all ends it, and even then what was
/// already said is transcribed and delivered.
final class InputRoutePolicyTests: XCTestCase {
    private let builtIn = SystemAudioInput.Device(
        id: 1, uid: "built-in", name: "MacBook Pro Microphone",
        transportType: kAudioDeviceTransportTypeBuiltIn, nominalSampleRate: 48_000
    )
    private let airPods = SystemAudioInput.Device(
        id: 2, uid: "airpods", name: "AirPods Pro",
        transportType: kAudioDeviceTransportTypeBluetooth, nominalSampleRate: 24_000
    )
    private let usb = SystemAudioInput.Device(
        id: 3, uid: "usb", name: "USB Microphone",
        transportType: kAudioDeviceTransportTypeUSB, nominalSampleRate: 48_000
    )

    private func binding(
        _ device: SystemAudioInput.Device,
        channels: Int = 1,
        rate: Double = 48_000,
        mode: InputCaptureMode = .direct
    ) -> InputBinding {
        InputBinding(deviceID: device.id, sampleRate: rate, channelCount: channels, mode: mode)
    }

    private func snapshot(
        _ devices: [SystemAudioInput.Device],
        defaultID: AudioDeviceID?,
        alive: Bool = true,
        rate: Double? = 48_000,
        channels: Int? = 1
    ) -> InputRouteSnapshot {
        InputRouteSnapshot(
            devices: devices,
            defaultInputID: defaultID,
            boundIsAlive: alive,
            boundSampleRate: rate,
            boundChannelCount: channels
        )
    }

    // MARK: - The default input changed

    func testSystemDefaultFollowsTheNewDefaultMidUtterance() {
        let action = InputRoutePolicy.action(
            for: .defaultInputChanged,
            selection: .systemDefault,
            binding: binding(builtIn),
            snapshot: snapshot([builtIn, airPods], defaultID: airPods.id)
        )
        XCTAssertEqual(action, .rebind(airPods.id))
    }

    func testSystemDefaultStaysPutWhenTheDefaultIsStillTheBoundDevice() {
        let action = InputRoutePolicy.action(
            for: .defaultInputChanged,
            selection: .systemDefault,
            binding: binding(builtIn),
            snapshot: snapshot([builtIn, airPods], defaultID: builtIn.id)
        )
        XCTAssertEqual(action, .keep)
    }

    func testANamedDeviceIgnoresTheDefaultChanging() {
        for selection in [AudioInputSelection.builtIn, .device(uid: "usb")] {
            let action = InputRoutePolicy.action(
                for: .defaultInputChanged,
                selection: selection,
                binding: binding(builtIn),
                snapshot: snapshot([builtIn, airPods, usb], defaultID: airPods.id)
            )
            XCTAssertEqual(action, .keep, "\(selection) named a device; a new default is not news to it")
        }
    }

    // MARK: - The bound device changed shape

    /// The case the whole plan started from: a call page in Safari turns the
    /// built-in microphone into a 3-channel raw array for everyone.
    func testAChannelCountChangeRebindsToTheSameDevice() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceFormatChanged,
            selection: .systemDefault,
            binding: binding(builtIn, channels: 1),
            snapshot: snapshot([builtIn], defaultID: builtIn.id, channels: 3)
        )
        XCTAssertEqual(action, .rebind(builtIn.id))
    }

    func testASampleRateChangeRebindsToTheSameDevice() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceFormatChanged,
            selection: .builtIn,
            binding: binding(builtIn, rate: 48_000),
            snapshot: snapshot([builtIn], defaultID: builtIn.id, rate: 16_000)
        )
        XCTAssertEqual(action, .rebind(builtIn.id))
    }

    func testANoticeThatChangedNothingIsIgnored() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceFormatChanged,
            selection: .systemDefault,
            binding: binding(builtIn),
            snapshot: snapshot([builtIn], defaultID: builtIn.id)
        )
        XCTAssertEqual(action, .keep)
    }

    // MARK: - The bound device went away

    func testADeadDeviceFallsBackRatherThanEndingTheSentence() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceDied,
            selection: .device(uid: "usb"),
            binding: binding(usb),
            snapshot: snapshot([builtIn, usb], defaultID: builtIn.id, alive: false)
        )
        XCTAssertEqual(action, .rebind(builtIn.id), "The selection's own fallback order continues the utterance")
    }

    func testADeviceDisappearingFromTheListFallsBack() {
        let action = InputRoutePolicy.action(
            for: .deviceListChanged,
            selection: .device(uid: "usb"),
            binding: binding(usb),
            snapshot: snapshot([builtIn], defaultID: builtIn.id)
        )
        XCTAssertEqual(action, .rebind(builtIn.id))
    }

    func testTheLastInputGoingAwayEndsTheUtterance() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceDied,
            selection: .systemDefault,
            binding: binding(builtIn),
            snapshot: snapshot([], defaultID: nil, alive: false)
        )
        XCTAssertEqual(action, .interrupt(.noInputDevice))
    }

    /// Switching back the moment the preferred device returns is how capture
    /// would flap between two microphones inside one sentence.
    func testThePreferredDeviceComingBackDoesNotSwitchMidUtterance() {
        let action = InputRoutePolicy.action(
            for: .deviceListChanged,
            selection: .device(uid: "usb"),
            binding: binding(builtIn),
            snapshot: snapshot([builtIn, usb], defaultID: builtIn.id)
        )
        XCTAssertEqual(action, .keep)
    }

    func testAnUnrelatedDeviceAppearingChangesNothing() {
        let action = InputRoutePolicy.action(
            for: .deviceListChanged,
            selection: .systemDefault,
            binding: binding(builtIn),
            snapshot: snapshot([builtIn, airPods], defaultID: builtIn.id)
        )
        XCTAssertEqual(action, .keep)
    }

    // MARK: - The callbacks stopped

    func testAStallOnALivingDeviceReopensTheSameDevice() {
        let action = InputRoutePolicy.action(
            for: .inputStalled,
            selection: .systemDefault,
            binding: binding(builtIn),
            snapshot: snapshot([builtIn, airPods], defaultID: airPods.id)
        )
        XCTAssertEqual(
            action, .rebind(builtIn.id),
            "A transient stall is not a reason to drift onto another microphone"
        )
    }

    func testAStallOnAVanishedDeviceResolvesAgain() {
        let action = InputRoutePolicy.action(
            for: .inputStalled,
            selection: .systemDefault,
            binding: binding(usb),
            snapshot: snapshot([builtIn], defaultID: builtIn.id, alive: false)
        )
        XCTAssertEqual(action, .rebind(builtIn.id))
    }

    // MARK: - A device that answers without its microphone

    /// AirPods paired to this Mac and to a phone that is playing music: the
    /// device is alive, is the default input, and hands us bit-exact zeros for
    /// as long as we care to record. There is no stronger claim left to make on
    /// it, so the recording moves to a microphone that works.
    func testADeviceDeliveringOnlySilenceIsLeftForAnotherOne() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceDeliveredSilence,
            selection: .systemDefault,
            binding: binding(airPods, rate: 24_000),
            snapshot: snapshot([builtIn, airPods], defaultID: airPods.id)
        )
        XCTAssertEqual(action, .rebind(builtIn.id))
    }

    /// A Mac with no microphone of its own, and a headset that is listening to
    /// something else. Taking the headset stops what the user was hearing, which
    /// is why it is never the first answer; here it is the only one.
    func testTheOnlyMicrophoneBeingAHeadsetEarnsTheStrongerClaim() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceDeliveredSilence,
            selection: .systemDefault,
            binding: binding(airPods, rate: 24_000),
            snapshot: snapshot([airPods], defaultID: airPods.id)
        )
        XCTAssertEqual(action, .escalate(airPods.id))
    }

    func testTheStrongerClaimIsNotMadeTwice() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceDeliveredSilence,
            selection: .systemDefault,
            binding: binding(airPods, rate: 24_000, mode: .voiceProcessing),
            snapshot: snapshot([airPods], defaultID: airPods.id)
        )
        XCTAssertEqual(
            action, .keep,
            "Ending the sentence would add a second wrong answer to the first; the notice tells the truth about the silence"
        )
    }

    func testALocalMicrophoneThatGoesSilentIsLeftAlone() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceDeliveredSilence,
            selection: .systemDefault,
            binding: binding(builtIn),
            snapshot: snapshot([builtIn], defaultID: builtIn.id)
        )
        XCTAssertEqual(
            action, .keep,
            "Exact zeros from a local microphone mean someone muted it, and voice processing would not change that"
        )
    }

    func testANamedDeviceDeliveringOnlySilenceAlsoMovesOn() {
        let action = InputRoutePolicy.action(
            for: .boundDeviceDeliveredSilence,
            selection: .device(uid: airPods.uid),
            binding: binding(airPods, rate: 24_000),
            snapshot: snapshot([builtIn, airPods], defaultID: airPods.id)
        )
        XCTAssertEqual(
            action, .rebind(builtIn.id),
            "A chosen device that delivers nothing is not a reason to record nothing"
        )
    }

    // MARK: - Precedence inside a burst

    func testADeadDeviceOutranksEverythingElseInABurst() {
        let ordered = [
            InputRouteEvent.deviceListChanged,
            .boundDeviceFormatChanged,
            .defaultInputChanged,
            .inputStalled,
            .boundDeviceDeliveredSilence,
            .boundDeviceDied,
        ]
        XCTAssertEqual(ordered.sorted { $0.precedence < $1.precedence }, ordered)
    }

    // MARK: - The retry budget

    func testFourAttemptsAreAllowedInsideTheWindow() {
        var budget = RebindBudget()
        for attempt in 1...4 {
            XCTAssertTrue(budget.allowsAttempt(at: Double(attempt) * 0.1), "Attempt \(attempt) must be allowed")
        }
        XCTAssertFalse(budget.allowsAttempt(at: 0.5), "A device that flaps must not be retried forever")
    }

    func testTheBudgetRefillsOnceTheWindowHasPassed() {
        var budget = RebindBudget()
        for attempt in 1...4 { _ = budget.allowsAttempt(at: Double(attempt) * 0.1) }
        XCTAssertFalse(budget.allowsAttempt(at: 0.5))
        XCTAssertTrue(budget.allowsAttempt(at: 3.0))
    }

    func testARebindThatWorkedGivesTheNextOneAFullBudget() {
        var budget = RebindBudget()
        for attempt in 1...4 { _ = budget.allowsAttempt(at: Double(attempt) * 0.1) }
        budget.recordSuccess()
        XCTAssertTrue(budget.allowsAttempt(at: 0.5))
    }

    func testAMissingInputIsToleratedForTwoSecondsAndNoLonger() {
        var budget = RebindBudget()
        XCTAssertTrue(budget.toleratesMissingInput(at: 10))
        XCTAssertTrue(budget.toleratesMissingInput(at: 11.9))
        XCTAssertFalse(budget.toleratesMissingInput(at: 12.1))
    }

    func testAnInputThatCameBackResetsTheWait() {
        var budget = RebindBudget()
        XCTAssertTrue(budget.toleratesMissingInput(at: 10))
        budget.recordSuccess()
        XCTAssertTrue(budget.toleratesMissingInput(at: 13))
    }

    // MARK: - Starting away from a silent headset

    private let marked = Date(timeIntervalSinceReferenceDate: 1_000)

    private func memoryOfSilentAirPods() -> SilentInputMemory {
        var memory = SilentInputMemory()
        memory.remember(airPods, defaultInputID: airPods.id, at: marked)
        return memory
    }

    /// The 2026-10-07 report: AirPods shared with a phone were the default
    /// input, every recording opened on them and left for the built-in
    /// microphone 1.2 s in, and the first word of every sentence was lost. The
    /// second press must start where the first one ended up.
    func testTheNextRecordingStartsAwayFromAHeadsetThatWasSilent() throws {
        var memory = memoryOfSilentAirPods()
        let devices = [builtIn, airPods]
        let avoid = memory.deviceToAvoid(among: devices, defaultInputID: airPods.id, at: marked.addingTimeInterval(60))

        let start = try XCTUnwrap(
            SystemAudioInput.resolveStart(.systemDefault, among: devices, defaultID: airPods.id, avoiding: avoid)
        )
        XCTAssertEqual(start.resolution.device, builtIn)
        XCTAssertEqual(start.skipped, airPods, "The skip is logged, so a report can tell it happened")
    }

    func testANamedSilentHeadsetIsAlsoSkippedAtTheStart() throws {
        var memory = memoryOfSilentAirPods()
        let devices = [builtIn, airPods]
        let avoid = memory.deviceToAvoid(among: devices, defaultInputID: airPods.id, at: marked.addingTimeInterval(60))

        let start = try XCTUnwrap(
            SystemAudioInput.resolveStart(.device(uid: airPods.uid), among: devices, defaultID: airPods.id, avoiding: avoid)
        )
        XCTAssertEqual(start.resolution.device, builtIn, "Mid-sentence the policy leaves it too; the start agrees")
    }

    /// With no other microphone the silent headset is still opened, so the
    /// route policy can make the stronger claim on it instead of recording
    /// nothing.
    func testASilentHeadsetIsStillUsedWhenItIsTheOnlyMicrophone() throws {
        var memory = memoryOfSilentAirPods()
        let avoid = memory.deviceToAvoid(among: [airPods], defaultInputID: airPods.id, at: marked.addingTimeInterval(60))

        let start = try XCTUnwrap(
            SystemAudioInput.resolveStart(.systemDefault, among: [airPods], defaultID: airPods.id, avoiding: avoid)
        )
        XCTAssertEqual(start.resolution.device, airPods)
        XCTAssertNil(start.skipped)
    }

    func testARecordingThatWouldNotHaveUsedTheHeadsetIsUntouched() throws {
        var memory = memoryOfSilentAirPods()
        let devices = [builtIn, airPods, usb]
        let avoid = memory.deviceToAvoid(among: devices, defaultInputID: airPods.id, at: marked.addingTimeInterval(60))

        let start = try XCTUnwrap(
            SystemAudioInput.resolveStart(.device(uid: usb.uid), among: devices, defaultID: airPods.id, avoiding: avoid)
        )
        XCTAssertEqual(start.resolution.device, usb)
        XCTAssertFalse(start.resolution.usedFallback)
        XCTAssertNil(start.skipped)
    }

    func testTheVerdictExpiresSoTheHeadsetGetsAnotherChance() {
        var memory = memoryOfSilentAirPods()
        let devices = [builtIn, airPods]
        XCTAssertEqual(
            memory.deviceToAvoid(among: devices, defaultInputID: airPods.id, at: marked.addingTimeInterval(29 * 60)),
            airPods
        )
        XCTAssertNil(memory.deviceToAvoid(among: devices, defaultInputID: airPods.id, at: marked.addingTimeInterval(31 * 60)))
        XCTAssertNil(
            memory.deviceToAvoid(among: devices, defaultInputID: airPods.id, at: marked.addingTimeInterval(60)),
            "An expired verdict is dropped, not revived by an earlier clock"
        )
    }

    func testAReconnectedHeadsetIsTrustedAgain() {
        var memory = memoryOfSilentAirPods()
        let reconnected = SystemAudioInput.Device(
            id: 9, uid: airPods.uid, name: airPods.name,
            transportType: airPods.transportType, nominalSampleRate: 24_000
        )
        XCTAssertNil(
            memory.deviceToAvoid(among: [builtIn, reconnected], defaultInputID: reconnected.id, at: marked.addingTimeInterval(60))
        )
    }

    func testAHeadsetThatLeftIsForgotten() {
        var memory = memoryOfSilentAirPods()
        XCTAssertNil(memory.deviceToAvoid(among: [builtIn], defaultInputID: builtIn.id, at: marked.addingTimeInterval(60)))
        XCTAssertNil(
            memory.deviceToAvoid(among: [builtIn, airPods], defaultInputID: airPods.id, at: marked.addingTimeInterval(120)),
            "Coming back is a new connection, not the one that was silent"
        )
    }

    func testAMovedDefaultInputDropsTheVerdict() {
        var memory = memoryOfSilentAirPods()
        XCTAssertNil(
            memory.deviceToAvoid(among: [builtIn, airPods], defaultInputID: builtIn.id, at: marked.addingTimeInterval(60))
        )
    }
}
