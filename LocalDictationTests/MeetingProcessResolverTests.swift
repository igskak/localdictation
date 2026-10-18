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
}

private struct FakeMeetingProcessResolver: MeetingProcessResolving {
    let result: Result<[MeetingAudioProcess], MeetingProcessError>
    func processes() throws -> [MeetingAudioProcess] { try result.get() }
}
