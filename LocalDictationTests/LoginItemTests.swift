import ServiceManagement
import XCTest
@testable import Witness

/// Whether the app is there when the user logs in.
///
/// The states matter more than the switch. Three of the four answers macOS can
/// give need a different sentence, and two of them cannot be fixed from inside
/// the app at all — which is the difference between a toggle that does nothing
/// and a toggle that says why.
@MainActor
final class LoginItemTests: XCTestCase {
    func testEveryAnswerMacOSCanGiveHasAState() {
        XCTAssertEqual(SMAppServiceLoginItem.state(for: .enabled), .enabled)
        XCTAssertEqual(SMAppServiceLoginItem.state(for: .notRegistered), .disabled)
        XCTAssertEqual(SMAppServiceLoginItem.state(for: .requiresApproval), .requiresApproval)
        guard case .unavailable = SMAppServiceLoginItem.state(for: .notFound) else {
            return XCTFail("A copy macOS cannot find is not the same as one the user switched off")
        }
    }

    /// The two states the app cannot change are the two that have to explain
    /// themselves, or the user is left with a switch that silently refuses.
    func testTheStatesTheAppCannotChangeExplainThemselves() {
        XCTAssertNil(LoginItemState.enabled.explanation)
        XCTAssertNil(LoginItemState.disabled.explanation)
        XCTAssertNotNil(LoginItemState.requiresApproval.explanation)
        XCTAssertNotNil(LoginItemState.unavailable("moved").explanation)
    }

    func testApprovalHeldBySystemSettingsPointsAtSystemSettings() {
        let explanation = try? XCTUnwrap(LoginItemState.requiresApproval.explanation)
        XCTAssertTrue(explanation?.contains("Login Items") ?? false)
    }

    func testTheControllerShowsWhateverTheServiceSays() {
        let service = FakeLoginItemService(.disabled)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertFalse(controller.state.isEnabled)

        controller.setEnabled(true)

        XCTAssertTrue(controller.state.isEnabled)
        XCTAssertEqual(service.calls, [true])
    }

    /// A refusal has to reach the switch, or the app shows a setting that is on
    /// while the Mac disagrees.
    func testARefusalIsWhatTheSwitchEndsUpShowing() {
        let service = FakeLoginItemService(.disabled)
        service.refuse(with: "macOS refused: a build running from Xcode cannot open at login")
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertFalse(controller.state.isEnabled)
        XCTAssertNotNil(controller.state.explanation)
    }
}
