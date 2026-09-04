import XCTest
@testable import LocalDictation

/// The two questions the live insertion service answers about applications
/// rather than about text: which one was dictated into, and whether it is still
/// the one in front.
///
/// Nothing here posts a key event or touches the user's pasteboard. The service
/// is built with the frontmost application scripted, which is the only way to
/// exercise a target that goes behind a system panel and comes back — the
/// panels that do it cannot be summoned from a test.
///
/// The one test that runs a whole insertion aims it at a process identifier no
/// Mac has, so the Accessibility calls it makes describe nothing and the
/// decision under test is reached with the target application's own behaviour
/// taken out of it.
@MainActor
final class AXTextInsertionServiceTests: XCTestCase {
    private let editor = FrontmostApplication(
        processIdentifier: 501,
        bundleIdentifier: "com.example.editor",
        localizedName: "Editor"
    )
    private let systemPanel = FrontmostApplication(
        processIdentifier: 425,
        bundleIdentifier: "com.apple.loginwindow",
        localizedName: "loginwindow"
    )

    private func service(frontmost: FakeFrontmostApplicationSource) -> AXTextInsertionService {
        AXTextInsertionService(
            permissionService: FakeAccessibilityPermissionService(authorization: .notTrusted),
            pasteboard: FakePasteboard(),
            frontmost: frontmost,
            eventSynthesis: FakeEventSynthesisSource()
        )
    }

    // MARK: - Capturing the target

    func testTheApplicationInFrontBecomesTheTarget() {
        let target = service(frontmost: FakeFrontmostApplicationSource([editor])).captureTarget()
        XCTAssertEqual(target?.processIdentifier, 501)
        XCTAssertEqual(target?.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(target?.displayName, "Editor")
    }

    func testWithNothingInFrontThereIsNoTarget() {
        XCTAssertNil(service(frontmost: FakeFrontmostApplicationSource([nil])).captureTarget())
    }

    /// Dictating with our own window in front is not a target: the result stays
    /// in the app for the user to copy.
    func testOurOwnApplicationIsNeverATarget() {
        let ourselves = FrontmostApplication(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: "com.localdictation.LocalDictation",
            localizedName: "LocalDictation"
        )
        XCTAssertNil(service(frontmost: FakeFrontmostApplicationSource([ourselves])).captureTarget())
    }

    // MARK: - Waiting for a target behind a system panel

    func testATargetAlreadyInFrontIsNotWaitedFor() async {
        let frontmost = FakeFrontmostApplicationSource([editor])
        let service = service(frontmost: frontmost)

        let came = await service.waitForTargetToComeBack(target(of: editor))

        XCTAssertTrue(came)
        XCTAssertEqual(frontmost.readCount, 1, "A target in front should cost exactly one read")
    }

    /// The case measured on a real Mac: `loginwindow` in front of the
    /// application being dictated into, for a couple of seconds, while the user
    /// went nowhere.
    func testATargetBehindASystemPanelIsWaitedForAndFound() async {
        let frontmost = FakeFrontmostApplicationSource([systemPanel, systemPanel, systemPanel, editor])
        let service = service(frontmost: frontmost)

        let came = await service.waitForTargetToComeBack(target(of: editor))

        XCTAssertTrue(came)
        XCTAssertEqual(frontmost.readCount, 4)
    }

    /// The user really did switch applications. The wait is bounded, and the
    /// answer is still no.
    func testATargetThatNeverComesBackIsGivenUpOn() async {
        let frontmost = FakeFrontmostApplicationSource([systemPanel])
        let service = service(frontmost: frontmost)

        let came = await service.waitForTargetToComeBack(target(of: editor))

        XCTAssertFalse(came)
        XCTAssertLessThanOrEqual(frontmost.readCount, 16, "The grace period must be bounded")
    }

    /// A target whose process has gone is not current, however the frontmost
    /// application reads.
    func testATerminatedTargetIsNotCurrent() async {
        let dead = FrontmostApplication(
            processIdentifier: 501,
            bundleIdentifier: "com.example.editor",
            localizedName: "Editor",
            isTerminated: true
        )
        let service = service(frontmost: FakeFrontmostApplicationSource([dead]))

        let came = await service.waitForTargetToComeBack(target(of: editor))

        XCTAssertFalse(came)
    }

    // MARK: - A ⌘V macOS will not let the app press

    /// The defect this covers cost a whole session of dictation, and the app
    /// described it as the target application's fault the entire time.
    ///
    /// On 2026-08-31 every paste produced two `Sender is prohibited from
    /// synthesizing events` errors from the window server — one per key event —
    /// while the target application logged no `performKeyEquivalent:` at all
    /// and took the user's own ⌘V a second later. `CGEventPost` returns `Void`,
    /// so the app saw an unchanged field and said the application would not
    /// accept the text. It would have; it was never asked.
    ///
    /// The text still ends up on the pasteboard, and is deliberately left
    /// there: the user's ⌘V is the only way in until the permission is
    /// restored, and restoring the previous contents would take the dictation
    /// away from them.
    func testAPasteMacOSWillNotPostIsReportedAsThePermissionItIs() async throws {
        let pasteboard = FakePasteboard()
        let service = AXTextInsertionService(
            permissionService: FakeAccessibilityPermissionService(authorization: .trusted),
            pasteboard: pasteboard,
            frontmost: FakeFrontmostApplicationSource([unreachable]),
            secureInput: FakeSecureInputSource(),
            eventSynthesis: FakeEventSynthesisSource(canSynthesizeEvents: false)
        )

        let outcome = await service.insert("die rechnung ist bezahlt", into: target(of: unreachable))

        XCTAssertEqual(outcome, .copiedToClipboard(.cannotSynthesizeEvents))
        XCTAssertEqual(pasteboard.writes, ["die rechnung ist bezahlt"])
        XCTAssertEqual(pasteboard.restoreCount, 0, "The dictation stays on the pasteboard: ⌘V is the only way in")

        let message = try XCTUnwrap(outcome.message)
        XCTAssertTrue(message.contains("Accessibility"), "The sentence has to name where the fix is")
    }

    /// The mirror of this test — the same insertion with the permission in
    /// place — is deliberately absent. It would reach `postCommandV` and put a
    /// real ⌘V into whatever the person running the tests has in front of them,
    /// which is a price no assertion here is worth. The permitted path is
    /// covered where it costs nothing, in `InsertionPolicyTests`.
    ///
    /// The guard inside `paste(_:into:)` is likewise not reachable from here:
    /// getting there needs a focused element that offers a direct write and
    /// then swallows it, which is a real Electron application rather than
    /// anything a test can stage. It is a second reading of the same fact, put
    /// where the Electron fallback passes.

    /// A process identifier no Mac has, so the Accessibility calls made on the
    /// way describe nothing and the target application's own behaviour is out
    /// of the test. macOS pids stop well below this.
    private let unreachable = FrontmostApplication(
        processIdentifier: 999_999,
        bundleIdentifier: "com.example.unreachable",
        localizedName: "Unreachable"
    )

    private func target(of application: FrontmostApplication) -> InsertionTarget {
        InsertionTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        )
    }
}
