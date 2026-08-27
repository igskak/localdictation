import XCTest
@testable import LocalDictation

/// The refusal a user is most likely to meet, and least able to act on.
///
/// Secure input is a single process-wide flag. While it is on, every dictation
/// everywhere is refused — `docs/PHASE_4_COMPATIBILITY.md` lists it as the
/// worst failure mode in the insertion path, because a whole app that has
/// stopped working looks like a broken app rather than a careful one. These
/// tests cover the sentence the user reads, which is the entire fix available
/// from inside this process.
@MainActor
final class SecureInputRefusalTests: XCTestCase {
    private let editor = FrontmostApplication(
        processIdentifier: 501,
        bundleIdentifier: "com.example.editor",
        localizedName: "Editor"
    )

    private func service(secureInput: SecureInputState) -> (AXTextInsertionService, FakePasteboard) {
        let pasteboard = FakePasteboard()
        let service = AXTextInsertionService(
            permissionService: FakeAccessibilityPermissionService(authorization: .trusted),
            pasteboard: pasteboard,
            frontmost: FakeFrontmostApplicationSource([editor, editor, editor]),
            secureInput: FakeSecureInputSource(secureInput)
        )
        return (service, pasteboard)
    }

    private var target: InsertionTarget {
        InsertionTarget(processIdentifier: 501, bundleIdentifier: "com.example.editor", applicationName: "Editor")
    }

    // MARK: - The refusal itself

    func testSecureInputRefusesAndLeavesThePasteboardAlone() async {
        let (service, pasteboard) = service(secureInput: SecureInputState(isEnabled: true))

        let outcome = await service.insert("die rechnung ist bezahlt", into: target)

        XCTAssertEqual(outcome, .refused(.secureInput))
        XCTAssertFalse(outcome.isOnClipboard)
        XCTAssertEqual(pasteboard.writes, [], "A refusal is the one outcome that leaves the clipboard alone")
    }

    func testTheApplicationHoldingSecureInputIsNamedToTheUser() async throws {
        let (service, _) = service(
            secureInput: SecureInputState(
                isEnabled: true,
                holderName: "1Password",
                holderBundleIdentifier: "com.1password.1password"
            )
        )

        let outcome = await service.insert("die rechnung ist bezahlt", into: target)

        XCTAssertEqual(outcome, .refused(.secureInput, holder: "1Password"))
        let message = try XCTUnwrap(outcome.message)
        XCTAssertTrue(message.contains("1Password"), "A name is what makes the refusal actionable")
    }

    func testAnUnnamedHolderStillGetsAWholeSentence() {
        let message = RefusalReason.secureInput.message()

        XCTAssertTrue(message.contains("secure input"))
        XCTAssertTrue(message.contains("was not copied"))
        XCTAssertFalse(message.contains("nil"))
    }

    /// A password field is the one the user is already looking at, so naming an
    /// application would be answering a question nobody asked.
    func testAPasswordFieldNamesNobody() {
        let message = RefusalReason.secureField.message(holder: "1Password")

        XCTAssertFalse(message.contains("1Password"))
        XCTAssertTrue(message.contains("password field"))
    }

    // MARK: - What the log may carry

    func testTheLogIdentityIsABundleIdentifierAndNeverAName() {
        let state = SecureInputState(
            isEnabled: true,
            holderName: "1Password",
            holderBundleIdentifier: "com.1password.1password"
        )

        XCTAssertEqual(state.logIdentity, "com.1password.1password")
        XCTAssertNotEqual(state.logIdentity, state.holderName)
    }

    func testTheOutcomeLabelIsUnchangedByAHolder() {
        XCTAssertEqual(InsertionOutcome.refused(.secureInput).logLabel, "refused:secureInput")
        XCTAssertEqual(
            InsertionOutcome.refused(.secureInput, holder: "1Password").logLabel,
            "refused:secureInput",
            "The holder is shown to the user; the log stays a fixed set of labels"
        )
    }

    // MARK: - Saying so before a dictation is spent on it

    private func coordinator(secureInput: SecureInputState) -> DictationCoordinator {
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService(),
            secureInputSource: FakeSecureInputSource(secureInput)
        )
        coordinator.activate()
        return coordinator
    }

    func testTheMenuSaysWhoIsBlockingDictationBeforeAnyIsSpentOnIt() throws {
        let coordinator = coordinator(
            secureInput: SecureInputState(
                isEnabled: true,
                holderName: "1Password",
                holderBundleIdentifier: "com.1password.1password"
            )
        )

        let warning = try XCTUnwrap(coordinator.secureInputWarning)
        XCTAssertTrue(warning.contains("1Password"))
    }

    func testWithSecureInputOffTheMenuSaysNothingAboutIt() {
        XCTAssertNil(coordinator(secureInput: .off).secureInputWarning)
    }

    func testTheWarningFollowsTheFlagWithoutARestart() {
        let source = FakeSecureInputSource(.off)
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService(),
            secureInputSource: source
        )
        coordinator.activate()
        XCTAssertNil(coordinator.secureInputWarning)

        source.secureInputState = SecureInputState(isEnabled: true, holderName: "Terminal")
        // What opening the menu does.
        coordinator.refreshAuthorization()

        XCTAssertNotNil(coordinator.secureInputWarning)
    }

    /// Without a source — every test that does not care, and the Phase 5 world
    /// — nothing is warned about and nothing breaks.
    func testWithoutASourceThereIsNoWarning() {
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService()
        )
        coordinator.activate()

        XCTAssertNil(coordinator.secureInputWarning)
        XCTAssertFalse(coordinator.secureInput.isEnabled)
    }

    // MARK: - The decision

    func testSecureInputOutranksEverythingElseIncludingTrust() {
        let context = InsertionContext(
            isTrusted: false,
            hasTarget: false,
            secureInputEnabled: true,
            secureInputHolderName: "Terminal"
        )

        XCTAssertEqual(InsertionPolicy.plan(for: context), .refuse(.secureInput))
    }

    func testWithoutSecureInputTheHolderChangesNothing() {
        let context = InsertionContext(secureInputEnabled: false, secureInputHolderName: "Terminal")

        XCTAssertEqual(InsertionPolicy.plan(for: context), .write)
    }
}
