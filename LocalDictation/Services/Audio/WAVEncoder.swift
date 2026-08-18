#if DEBUG
import Foundation

/// Debug-only WAV encoder used by the manual diagnostics export.
///
/// Compiled out of Release builds. Normal capture never calls it: the export is a
/// separate action that requires the user to pick a destination in a save panel.
enum WAVEncoder {
    static let headerByteCount = 44

    /// Encodes Float32 samples as 16-bit PCM WAV.
    static func encode(samples: [Float], sampleRate: Double, channelCount: Int = 1) -> Data {
        let bitsPerSample = 16
        let byteRate = Int(sampleRate) * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataByteCount = samples.count * bitsPerSample / 8

        var data = Data(capacity: headerByteCount + dataByteCount)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32: UInt32(36 + dataByteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32: 16)
        data.append(uint16: 1) // PCM
        data.append(uint16: UInt16(channelCount))
        data.append(uint32: UInt32(sampleRate))
        data.append(uint32: UInt32(byteRate))
        data.append(uint16: UInt16(blockAlign))
        data.append(uint16: UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32: UInt32(dataByteCount))

        for sample in samples {
            let clamped = min(max(sample, -1), 1)
            let scaled = clamped < 0 ? clamped * 32768 : clamped * 32767
            data.append(int16: Int16(scaled.rounded()))
        }

        return data
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(int16 value: Int16) {
        append(uint16: UInt16(bitPattern: value))
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
#endif
