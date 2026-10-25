import ApplicationServices
import Foundation

/// Who the meeting application says is talking, read from its own window.
///
/// Wispr Flow does not separate remote voices acoustically at all: it labels
/// "You" and "Others" by source and takes the names from the meeting app's
/// Accessibility tree. A name shown by Zoom or Meet is real, needs no model and
/// cannot split one person into three, which is what the acoustic diarizer did
/// to the first real recording. The cost is that every application needs its own
/// reading and can change it in any update.
///
/// **Nothing here has been checked against a live call.** The patterns below are
/// the labels these applications are known or expected to show; the
/// `--notetaker-ax-probe` launch argument prints what the tree of a running
/// meeting actually contains so they can be corrected. Names are participants'
/// display names and stay in the local note like the words do.
enum ActiveSpeakerNameParser {
    private static let prefixes = [
        "talking:", "speaking:", "active speaker:", "now speaking:",
        "spricht:", "sprecher:", "говорит:", "розмовляє:", "говорить:",
    ]
    private static let suffixes = [
        " is speaking", " is talking", " spricht", " говорит", " говорить", " розмовляє",
    ]

    /// The name in a label, or nil when the label is not about a speaker.
    static func name(in label: String) -> String? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80 else { return nil }
        let lower = text.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            return clean(String(text.dropFirst(prefix.count)))
        }
        for suffix in suffixes where lower.hasSuffix(suffix) {
            return clean(String(text.dropLast(suffix.count)))
        }
        return nil
    }

    private static func clean(_ raw: String) -> String? {
        let first = raw.split(whereSeparator: { ",;\n|".contains($0) }).first.map(String.init) ?? raw
        let name = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), name.contains(where: \.isLetter) else { return nil }
        return name
    }
}

/// A sampled answer, positioned on the system-audio timeline.
struct ActiveSpeakerSample: Sendable, Equatable {
    let frame: Int64
    let name: String?
}

/// Samples taken twice a second, queried by a recognised row's span.
struct ActiveSpeakerTimeline: Sendable, Equatable {
    private(set) var samples: [ActiveSpeakerSample] = []
    /// A sample speaks for this long after it is taken.
    static let sampleSpanFrames: Int64 = 8_000

    mutating func record(_ sample: ActiveSpeakerSample) {
        if let last = samples.last, sample.frame < last.frame { return }
        samples.append(sample)
    }

    var isEmpty: Bool { !samples.contains { $0.name != nil } }

    /// The one name that was shown for most of the row, if the row was covered
    /// well enough to say. Silence in the signal (nobody highlighted) is not a
    /// vote for anyone, and two names at once are not resolved by guessing.
    func name(from start: Int64, to end: Int64, minimumShare: Double = 0.6) -> String? {
        let inside = samples.filter { $0.frame + Self.sampleSpanFrames > start && $0.frame < end }
        let named = inside.compactMap(\.name)
        guard !named.isEmpty else { return nil }
        let counts = Dictionary(grouping: named, by: { $0 }).mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        return Double(top.value) / Double(named.count) >= minimumShare ? top.key : nil
    }
}

/// Gives each distinct name a stable `speaker-N` and keeps the name for display,
/// so the library's existing rename and reassign controls keep working.
struct ActiveSpeakerRoster: Sendable, Equatable {
    private(set) var names: [String] = []
    static let capacity = 8

    mutating func speakerID(for name: String) -> String? {
        let key = name.lowercased()
        if let index = names.firstIndex(where: { $0.lowercased() == key }) { return "speaker-\(index + 1)" }
        guard names.count < Self.capacity else { return nil }
        names.append(name)
        return "speaker-\(names.count)"
    }

    var displayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: names.enumerated().map { ("speaker-\($0.offset + 1)", $0.element) })
    }
}

/// How far the acoustic labels agree with the application's names.
///
/// This is the free ground truth the corpus gate lacked: for every acoustic
/// speaker, the share of its time that carries its most common name, weighted by
/// time. 1.0 means each acoustic speaker is one named person; a model that
/// splits or merges people scores lower. It is a measurement of the model
/// against the application's signal, not against what was said.
enum SpeakerAgreement {
    static func purity(acoustic: [MeetingTranscriptRow], named: [MeetingTranscriptRow]) -> Double? {
        var seconds: [String: [String: Double]] = [:]
        var total = 0.0
        for row in acoustic where row.source == .system {
            // An acoustic row can span several named rows; each one is its own vote.
            for match in named where match.speakerID != "others" && match.startFrame < row.endFrame && match.endFrame > row.startFrame {
                let overlap = Double(min(row.endFrame, match.endFrame) - max(row.startFrame, match.startFrame)) / 16_000
                guard overlap > 0 else { continue }
                seconds[row.speakerID, default: [:]][match.speakerID, default: 0] += overlap
                total += overlap
            }
        }
        guard total > 0 else { return nil }
        return seconds.values.reduce(0) { $0 + ($1.values.max() ?? 0) } / total
    }
}

/// Reads the application's tree for a speaker label. Bounded so that a heavy
/// window cannot stall the sampling: a fixed number of nodes, a short per-call
/// timeout, and an immediate nil when Accessibility is not granted.
protocol ActiveSpeakerReading: Sendable {
    func currentSpeaker() -> String?
}

struct AXActiveSpeakerReader: ActiveSpeakerReading {
    let processID: pid_t
    var nodeLimit = 600

    func currentSpeaker() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        for label in Self.labels(processID: processID, nodeLimit: nodeLimit) {
            if let name = ActiveSpeakerNameParser.name(in: label) { return name }
        }
        return nil
    }

    /// Every title, value and description in the tree, breadth first. Also the
    /// body of the probe, which prints these for a person to read.
    static func labels(processID: pid_t, nodeLimit: Int) -> [String] {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var queue: [AXUIElement] = [application]
        var labels: [String] = []
        var visited = 0
        while !queue.isEmpty, visited < nodeLimit {
            let element = queue.removeFirst()
            visited += 1
            for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let text = value as? String, !text.isEmpty {
                    labels.append(text)
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        return labels
    }
}

/// Samples a reader twice a second on its own queue and reports to a callback.
final class MeetingSpeakerPoller: @unchecked Sendable {
    private let reader: any ActiveSpeakerReading
    private let queue = DispatchQueue(label: "witness.meeting-speaker-poller", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let interval: DispatchTimeInterval

    init(reader: any ActiveSpeakerReading, interval: DispatchTimeInterval = .milliseconds(500)) {
        self.reader = reader
        self.interval = interval
    }

    func start(_ onSample: @escaping @Sendable (String?) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [reader] in onSample(reader.currentSpeaker()) }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
