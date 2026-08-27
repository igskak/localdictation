#if DEBUG
import AVFoundation
import Foundation

/// One scored item: an audio file plus the text that should have come out.
struct BenchmarkSample: Sendable, Codable, Equatable {
    /// Path relative to the corpus directory.
    let audio: String
    let reference: String
    let language: SpeechLanguage
    /// Profile identifier such as `de` or `de+en`. Defaults to the language's
    /// own single-language profile.
    let profile: String?

    var languageProfile: LanguageProfile {
        if let profile, let resolved = LanguageProfile.profile(id: profile) { return resolved }
        return LanguageProfile(primary: language, secondary: nil)
    }
}

enum BenchmarkCorpusError: Error, Equatable {
    case manifestMissing(String)
    case audioMissing(String)
    case unreadableAudio(String)

    var message: String {
        switch self {
        case let .manifestMissing(path): "No corpus manifest at \(path)"
        case let .audioMissing(path): "Missing audio file: \(path)"
        case let .unreadableAudio(detail): "Could not read audio: \(detail)"
        }
    }
}

/// An evaluation corpus described by a `corpus.json` manifest.
///
/// The corpus lives outside the repository — `/Benchmark/` is git-ignored — so
/// licensed speech data is never committed and never leaves the machine.
struct BenchmarkCorpus: Sendable, Codable, Equatable {
    let name: String
    let samples: [BenchmarkSample]

    static let manifestName = "corpus.json"

    static func load(from directory: URL) throws -> BenchmarkCorpus {
        let manifest = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw BenchmarkCorpusError.manifestMissing(manifest.path)
        }
        let data = try Data(contentsOf: manifest)
        return try JSONDecoder().decode(BenchmarkCorpus.self, from: data)
    }

    func samples(for language: SpeechLanguage) -> [BenchmarkSample] {
        samples.filter { $0.language == language }
    }

    var languages: [SpeechLanguage] {
        Set(samples.map(\.language)).sorted()
    }

    /// Decodes one sample into the same normalized form the live capture path
    /// produces, so an engine sees benchmark audio and dictated audio alike.
    func utterance(for sample: BenchmarkSample, in directory: URL) throws -> CapturedUtterance {
        let url = directory.appendingPathComponent(sample.audio)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchmarkCorpusError.audioMissing(url.path)
        }

        let samples: [Float]
        do {
            samples = try Self.decode(url)
        } catch let error as BenchmarkCorpusError {
            throw error
        } catch {
            throw BenchmarkCorpusError.unreadableAudio(error.localizedDescription)
        }

        var peak: Float = 0
        for value in samples { peak = max(peak, abs(value)) }

        return CapturedUtterance(
            samples: samples,
            sampleRate: AudioTargetFormat.sampleRate,
            peakLevel: peak,
            droppedFrameCount: 0,
            voiceActivity: .initial,
            endReason: .hotkeyRelease
        )
    }

    /// Reads any format Core Audio understands and normalizes it to mono
    /// Float32 at 16 kHz, reusing the live capture converter.
    private static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw BenchmarkCorpusError.unreadableAudio("Could not allocate a read buffer for \(url.lastPathComponent)")
        }
        try file.read(into: input)

        let converter = try AudioFormatConverter(
            inputFormat: inputFormat,
            maximumInputFrames: max(frameCount, 8192)
        )
        var output = try converter.convertToArray(input)
        output.append(contentsOf: try converter.drainToArray())
        return output
    }
}
#endif
