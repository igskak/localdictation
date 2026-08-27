import AVFoundation
import XCTest
@testable import LocalDictation

/// Guards the "audio never touches disk" product constraint by running the real
/// capture data path (converter + bounded buffer + detector) over synthetic
/// buffers and verifying that no file appears anywhere the app can write.
final class CapturePrivacyTests: XCTestCase {
    /// Locations the app could write to without user interaction, and that no
    /// other process writes to while this runs.
    ///
    /// Deliberately excludes `~/Documents` and other TCC-protected folders:
    /// probing those would raise a macOS file-access dialog, and these tests must
    /// never trigger a system prompt.
    ///
    /// It also excludes the shared temporary directory, which is handled
    /// separately below. The test target runs its classes in parallel
    /// processes, and the ones covering the glossary, the licensing record, and
    /// the issuer tool each create throwaway directories there — so an exact
    /// listing of it is a comparison against other tests' work, and it fails
    /// whenever the scheduling happens to interleave. That is a defect in this
    /// test, not a write by the capture path, and it cost a green suite once.
    private func exclusiveDirectories() -> [URL] {
        let manager = FileManager.default
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.localdictation.LocalDictation"

        var urls = [URL(fileURLWithPath: manager.currentDirectoryPath)]
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            urls.append(
                contentsOf: manager.urls(for: directory, in: .userDomainMask)
                    .map { $0.appendingPathComponent(bundleIdentifier) }
            )
        }
        return urls
    }

    /// The shared temporary directory, in both of the forms the app could reach
    /// it by.
    private func sharedTemporaryDirectories() -> [URL] {
        [URL(fileURLWithPath: NSTemporaryDirectory()), FileManager.default.temporaryDirectory]
    }

    /// Everything the capture path could produce from audio.
    ///
    /// This is what keeps the shared temporary directory in the test at all.
    /// An exact listing of it is not available, but attribution is: the only
    /// file this app ever writes from an utterance is a WAV, and no sibling
    /// test writes audio of any kind. A recording appearing there would be
    /// caught; another test's `license-…` home would not.
    private static let audioExtensions: Set<String> = ["wav", "caf", "aif", "aiff", "m4a", "mp3", "pcm", "raw"]

    private func audioFiles(in directories: [URL]) -> Set<String> {
        var names: Set<String> = []
        for url in directories {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in contents where Self.audioExtensions.contains((name as NSString).pathExtension.lowercased()) {
                names.insert(url.appendingPathComponent(name).path)
            }
        }
        return names
    }

    /// Stable descriptor of each watched directory: whether it exists and what it
    /// contains, so a newly created directory is caught as well as a new file.
    private func listing(of directories: [URL]) -> [String] {
        directories.map { url in
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
            let exists = FileManager.default.fileExists(atPath: url.path)
            return "\(url.path)|exists=\(exists)|\(contents.joined(separator: ","))"
        }
        .sorted()
    }

    func testNormalCapturePathWritesNothingToDisk() throws {
        let directories = exclusiveDirectories()
        let before = listing(of: directories)
        let audioBefore = audioFiles(in: sharedTemporaryDirectories())

        let inputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let converter = try AudioFormatConverter(inputFormat: inputFormat)
        let sink = PCMCaptureSink(
            capacityFrames: AudioCaptureConfiguration.default.bufferCapacityFrames,
            detector: EnergyVoiceActivityDetector()
        )

        for index in 0..<100 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            for frame in 0..<4_800 {
                channel[frame] = sin(2 * .pi * 180 * Float(index * 4_800 + frame) / 48_000) * 0.3
            }
            let converted = try converter.convert(buffer)
            sink.ingest(converted)
        }

        let utterance = sink.finish(reason: .hotkeyRelease)
        XCTAssertGreaterThan(utterance.frameCount, 0)
        XCTAssertEqual(utterance.sampleRate, 16_000)

        XCTAssertEqual(listing(of: directories), before, "Capture must not create any file")
        XCTAssertEqual(
            audioFiles(in: sharedTemporaryDirectories()).subtracting(audioBefore),
            [],
            "Capture must not leave audio anywhere, including the shared temporary directory"
        )
    }

    func testTenSecondsOfCaptureStaysWithinTheBoundedBuffer() throws {
        let configuration = AudioCaptureConfiguration(
            voiceActivity: VoiceActivityConfiguration(
                windowDuration: 0.02,
                speechThreshold: 0.05,
                silenceThreshold: 0.01,
                speechActivationWindows: 3,
                trailingSilenceDuration: 1,
                maximumUtteranceDuration: 2
            )
        )
        let sink = PCMCaptureSink(
            capacityFrames: configuration.bufferCapacityFrames,
            detector: EnergyVoiceActivityDetector(configuration: configuration.voiceActivity)
        )

        // Push ten seconds into a buffer sized for two.
        let chunk = [Float](repeating: 0.2, count: 1_600)
        for _ in 0..<100 {
            chunk.withUnsafeBufferPointer { sink.ingest($0) }
        }

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.frameCount, configuration.bufferCapacityFrames)
        XCTAssertEqual(snapshot.frameCount, 2 * 16_000)
        XCTAssertEqual(snapshot.droppedFrameCount, 160_000 - 32_000)
        XCTAssertTrue(snapshot.reachedCapacity)
        XCTAssertEqual(snapshot.voiceActivity.state, .endedByMaximumDuration)
    }

    func testConcurrentIngestAndSnapshotStayConsistent() async {
        let sink = PCMCaptureSink(capacityFrames: 160_000, detector: EnergyVoiceActivityDetector())
        let chunk = [Float](repeating: 0.1, count: 1_000)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<100 {
                    chunk.withUnsafeBufferPointer { sink.ingest($0) }
                }
            }
            group.addTask {
                for _ in 0..<100 {
                    _ = sink.snapshot()
                }
            }
        }

        XCTAssertEqual(sink.snapshot().frameCount, 100_000)
    }
}
