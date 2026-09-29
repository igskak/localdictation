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

    private func binding(_ device: SystemAudioInput.Device, channels: Int = 1, rate: Double = 48_000) -> InputBinding {
        InputBinding(deviceID: device.id, sampleRate: rate, channelCount: channels)
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

    // MARK: - Precedence inside a burst

    func testADeadDeviceOutranksEverythingElseInABurst() {
        let ordered = [
            InputRouteEvent.deviceListChanged,
            .boundDeviceFormatChanged,
            .defaultInputChanged,
            .inputStalled,
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
}
