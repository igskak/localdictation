import XCTest
@testable import LocalDictation

/// The two questions the live insertion service answers about applications
/// rather than about text: which one was dictated into, and whether it is still
/// the one in front.
///
/// Nothing here reaches Accessibility, posts a key event, or touches the
/// pasteboard. The service is built with the frontmost application scripted,
/// which is the only way to exercise a target that goes behind a system panel
/// and comes back — the panels that do it cannot be summoned from a test.
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
            frontmost: frontmost
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

    private func target(of application: FrontmostApplication) -> InsertionTarget {
        InsertionTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        )
    }
}
