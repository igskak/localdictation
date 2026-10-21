import CoreAudio
import XCTest
@testable import Witness

final class MeetingProcessResolverTests: XCTestCase {
    func testResolvesOnlyTheRequestedProcessIncludingAnInactiveProcess() throws {
        let first = MeetingAudioProcess(processID: 101, audioObjectID: 7, isProducingOutput: true)
        let second = MeetingAudioProcess(processID: 102, audioObjectID: 8, isProducingOutput: false)
        let resolver = FakeMeetingProcessResolver(result: .success([first, second]))
        XCTAssertEqual(try resolver.resolve(processID: 102), second)
        XCTAssertNil(try resolver.resolve(processID: 103))
    }

    func testReportsInventoryErrorsInsteadOfTreatingThemAsAnEmptyList() {
        let resolver = FakeMeetingProcessResolver(result: .failure(.coreAudio(-1)))
        XCTAssertThrowsError(try resolver.resolve(processID: 101)) {
            XCTAssertEqual($0 as? MeetingProcessError, .coreAudio(-1))
        }
    }

    func testAutomaticSelectionPrefersAnActiveSupportedMeetingApp() {
        let backgroundAudio = MeetingProcessOption(
            processID: 100,
            name: "Music",
            bundleIdentifier: "com.apple.Music",
            isProducingOutput: true
        )
        let chrome = MeetingProcessOption(
            processID: 102,
            name: "Google Chrome Helper",
            bundleIdentifier: "com.google.Chrome.helper",
            isProducingOutput: true
        )
        let zoom = MeetingProcessOption(
            processID: 101,
            name: "zoom.us",
            bundleIdentifier: "us.zoom.xos",
            isProducingOutput: true
        )

        XCTAssertEqual(MeetingProcessSelection.preferred(in: [backgroundAudio, chrome, zoom]), zoom)
    }

    func testAutomaticSelectionUsesAnOpenSupportedAppBeforeUnrelatedAudio() {
        let backgroundAudio = MeetingProcessOption(
            processID: 100,
            name: "Music",
            bundleIdentifier: "com.apple.Music",
            isProducingOutput: true
        )
        let chrome = MeetingProcessOption(
            processID: 102,
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            isProducingOutput: false
        )

        XCTAssertEqual(MeetingProcessSelection.preferred(in: [backgroundAudio, chrome]), chrome)
    }

    func testAutomaticSelectionDoesNotChooseAnInactiveUnrelatedProcess() {
        let inactive = MeetingProcessOption(
            processID: 100,
            name: "Finder",
            bundleIdentifier: "com.apple.finder",
            isProducingOutput: false
        )

        XCTAssertNil(MeetingProcessSelection.preferred(in: [inactive]))
    }
}

private struct FakeMeetingProcessResolver: MeetingProcessResolving {
    let result: Result<[MeetingAudioProcess], MeetingProcessError>
    func processes() throws -> [MeetingAudioProcess] { try result.get() }
}
