// Records the punctuation scripts read aloud into the live benchmark corpus.
//
//     swift Tools/record_punctuation_corpus.swift ru [output-directory]
//
// Default output: Benchmark/punctuation-live/ in this checkout (git-ignored,
// never committed). Recordings stay on this Mac.
//
// For each script the tool shows the text, records from the default input
// while you speak, and writes a mono WAV plus a corpus.json entry. It resumes
// where you stopped, so a language can be recorded in several sittings.
//
// Speak the way you dictate, not the way you read aloud. Do not say the
// punctuation. Where the text shows a paragraph break, pause the way you
// would between paragraphs. The first run asks for microphone access for the
// terminal application.
import AVFoundation
import Foundation

struct Sample: Codable {
    let audio: String
    let reference: String
    let language: String
    let kind: String
}

struct Manifest: Codable {
    var name: String
    var samples: [Sample]
}

let corpusName = "punctuation-live"
let languages = ["ru", "uk", "de", "en"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let language = arguments.first, languages.contains(language) else {
    fail("usage: swift Tools/record_punctuation_corpus.swift <ru|uk|de|en> [output-directory]")
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1])
    : root.appendingPathComponent("Benchmark").appendingPathComponent(corpusName)

// MARK: - Scripts and manifest

let scriptsURL = root.appendingPathComponent("Tools").appendingPathComponent("punctuation_corpus_scripts.json")
guard let scriptsData = try? Data(contentsOf: scriptsURL),
      let scripts = try? JSONSerialization.jsonObject(with: scriptsData) as? [String: Any],
      let byLanguage = scripts["languages"] as? [String: Any],
      let items = byLanguage[language] as? [[String]]
else { fail("Could not read \(scriptsURL.path)") }

let manifestURL = output.appendingPathComponent("corpus.json")
var manifest = Manifest(name: corpusName, samples: [])
if let data = try? Data(contentsOf: manifestURL) {
    guard let existing = try? JSONDecoder().decode(Manifest.self, from: data) else {
        fail("\(manifestURL.path) exists but is not a corpus manifest; move it aside")
    }
    guard existing.name == corpusName else {
        fail("Refusing to write into corpus '\(existing.name)' at \(output.path)")
    }
    manifest = existing
}

func saveManifest() {
    manifest.samples.sort { $0.audio < $1.audio }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    } catch {
        fail("Could not write \(manifestURL.path): \(error.localizedDescription)")
    }
}

// MARK: - Microphone

func microphoneAuthorized() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        let answered = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            granted = allowed
            answered.signal()
        }
        answered.wait()
        return granted
    default:
        return false
    }
}

/// Collects channel 0 of the default input in memory, so the key press that
/// stops a take can be trimmed off before anything is written.
final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var sampleRate: Double = 48_000

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw NSError(domain: "record", code: 1, userInfo: [NSLocalizedDescriptionKey: "Input is not Float32: \(format)"])
        }
        sampleRate = format.sampleRate
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops and returns the take without its last `tail` seconds, where the
    /// Return key that ended it was recorded.
    func stop(trimmingTail tail: Double = 0.2) -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let all = lock.withLock { samples }
        let drop = min(all.count, Int(tail * sampleRate))
        return Array(all.dropLast(drop))
    }
}

func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { throw NSError(domain: "record", code: 2) }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
}

func play(_ url: URL) {
    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    player.arguments = [url.path]
    try? player.run()
    player.waitUntilExit()
}

func prompt(_ text: String) -> String {
    print(text, terminator: " ")
    fflush(stdout)
    guard let line = readLine() else { exit(0) }
    return line.trimmingCharacters(in: .whitespaces).lowercased()
}

// MARK: - Session

guard microphoneAuthorized() else {
    fail("""
        No microphone access. Allow it for your terminal application under
        System Settings > Privacy & Security > Microphone, then run again.
        """)
}

let recorded = Set(manifest.samples.filter { sample in
    FileManager.default.fileExists(atPath: output.appendingPathComponent(sample.audio).path)
}.map(\.audio))
let remaining = items.indices.filter { !recorded.contains(String(format: "%@/%04d.wav", language, $0 + 1)) }

print("""

    \(language): \(items.count - remaining.count) of \(items.count) already recorded, \(remaining.count) to go.
    Output: \(output.path)

    Speak as you dictate, do not say the punctuation. Where you see
    [pause: new paragraph], pause as you would between paragraphs.

    """)

let recorder = Recorder()
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("punctuation-take.wav")

for index in remaining {
    let item = items[index]
    let kind = item[0]
    let text = item[1]
    let relative = String(format: "%@/%04d.wav", language, index + 1)

    print("────────────────────────────────────────")
    print("\(index + 1)/\(items.count)  [\(kind)]\n")
    print(text.replacingOccurrences(of: "\n\n", with: "\n    [pause: new paragraph]\n"))
    print("")

    take: while true {
        switch prompt("Return: record · s: skip · q: quit ›") {
        case "q":
            saveManifest()
            print("Saved. Run the same command again to continue.")
            exit(0)
        case "s":
            break take
        default:
            break
        }

        do {
            try recorder.start()
        } catch {
            fail("Could not start recording: \(error.localizedDescription)")
        }
        _ = prompt("● recording… Return to stop ›")
        let samples = recorder.stop()
        let seconds = Double(samples.count) / recorder.sampleRate
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        print(String(format: "  %.1f s, peak %.3f", seconds, peak))
        if peak < 0.01 { print("  Very quiet: check the input device in System Settings > Sound.") }

        do {
            try write(samples, sampleRate: recorder.sampleRate, to: scratch)
        } catch {
            fail("Could not write the take: \(error.localizedDescription)")
        }

        review: while true {
            switch prompt("Return: keep · r: redo · l: listen ›") {
            case "l":
                play(scratch)
                continue review
            case "r":
                continue take
            default:
                let destination = output.appendingPathComponent(relative)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: scratch, to: destination)
                } catch {
                    fail("Could not save \(destination.path): \(error.localizedDescription)")
                }
                manifest.samples.removeAll { $0.audio == relative }
                manifest.samples.append(Sample(audio: relative, reference: text, language: language, kind: kind))
                saveManifest()
                break take
            }
        }
    }
}

saveManifest()
print("\nDone: \(manifest.samples.filter { $0.language == language }.count) \(language) samples in \(manifestURL.path)")
