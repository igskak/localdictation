import XCTest
@testable import LocalDictation

#if DEBUG
final class WAVEncoderTests: XCTestCase {
    func testHeaderDescribesMono16BitPCM() {
        let data = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1], sampleRate: 16_000)

        XCTAssertEqual(data.count, WAVEncoder.headerByteCount + 4 * 2)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")

        XCTAssertEqual(readUInt16(data, at: 20), 1, "PCM format tag")
        XCTAssertEqual(readUInt16(data, at: 22), 1, "mono")
        XCTAssertEqual(readUInt32(data, at: 24), 16_000)
        XCTAssertEqual(readUInt16(data, at: 34), 16, "bits per sample")
        XCTAssertEqual(readUInt32(data, at: 40), 8, "payload byte count")
        XCTAssertEqual(readUInt32(data, at: 4), UInt32(36 + 8))
    }

    func testFullScaleSamplesAreClampedNotWrapped() {
        let data = WAVEncoder.encode(samples: [1, -1, 2, -2], sampleRate: 16_000)
        let payloadStart = WAVEncoder.headerByteCount

        XCTAssertEqual(readInt16(data, at: payloadStart), 32_767)
        XCTAssertEqual(readInt16(data, at: payloadStart + 2), -32_768)
        XCTAssertEqual(readInt16(data, at: payloadStart + 4), 32_767)
        XCTAssertEqual(readInt16(data, at: payloadStart + 6), -32_768)
    }

    func testEmptyUtteranceStillProducesAValidHeader() {
        let data = WAVEncoder.encode(samples: [], sampleRate: 16_000)
        XCTAssertEqual(data.count, WAVEncoder.headerByteCount)
        XCTAssertEqual(readUInt32(data, at: 40), 0)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readInt16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(data, at: offset))
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
#endif
