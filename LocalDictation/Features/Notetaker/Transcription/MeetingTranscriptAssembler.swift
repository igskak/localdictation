import Foundation

/// Original recognition output remains available even when the presentation
/// suppresses a duplicated boundary. Timestamps remain source-local evidence.
struct MeetingTranscriptWindow: Sendable, Equatable {
    let source: MeetingAudioSource
    let startFrame: Int64
    let endFrame: Int64
    let transcript: Transcript
}

struct MeetingTranscriptRow: Sendable, Equatable {
    let source: MeetingAudioSource
    let startFrame: Int64
    let endFrame: Int64
    let text: String
    let original: Transcript
    let speakerID: String
    let speakerConfidence: Double?
    let speakerAssignmentSource: SpeakerAssignmentSource
    let wordAttributions: [SpeakerWordAttribution]

    init(
        source: MeetingAudioSource,
        startFrame: Int64,
        endFrame: Int64,
        text: String,
        original: Transcript,
        speakerID: String? = nil,
        speakerConfidence: Double? = nil,
        speakerAssignmentSource: SpeakerAssignmentSource = .sourceFallback,
        wordAttributions: [SpeakerWordAttribution] = []
    ) {
        self.source = source
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.text = text
        self.original = original
        self.speakerID = speakerID ?? (source == .microphone ? "you" : "others")
        self.speakerConfidence = speakerConfidence
        self.speakerAssignmentSource = speakerAssignmentSource
        self.wordAttributions = wordAttributions
    }

    var speaker: String {
        switch speakerID {
        case "you": "You"
        case "others": "Others"
        default:
            if let number = speakerID.split(separator: "-").last,
               speakerID.hasPrefix("speaker-") {
                "Speaker \(number)"
            } else {
                speakerID
            }
        }
    }

    /// Low-confidence recognition remains visible as model evidence, but must
    /// never be presented with the same certainty as supported speech.
    var recognitionNeedsReview: Bool {
        MeetingRecognitionQualityPolicy.needsReview(
            meanConfidence: original.meanConfidence,
            hasConfidenceSignal: original.hasConfidenceSignal
        )
    }

    func attributed(
        speakerID: String,
        confidence: Double,
        words: [SpeakerWordAttribution],
        startFrame: Int64? = nil,
        endFrame: Int64? = nil,
        text: String? = nil
    ) -> MeetingTranscriptRow {
        MeetingTranscriptRow(
            source: source,
            startFrame: startFrame ?? self.startFrame,
            endFrame: endFrame ?? self.endFrame,
            text: text ?? self.text,
            original: original,
            speakerID: speakerID,
            speakerConfidence: min(max(confidence, 0), 1),
            speakerAssignmentSource: .diarization,
            wordAttributions: words
        )
    }
}

enum MeetingRecognitionQualityPolicy {
    /// Reuses the confidence threshold already calibrated and documented by
    /// the product's risk pipeline instead of inventing a Notetaker-only rule.
    static let confidenceThreshold = RiskWeights.default.confidenceThreshold

    static func needsReview(meanConfidence: Double?, hasConfidenceSignal: Bool) -> Bool {
        guard hasConfidenceSignal, let meanConfidence else { return true }
        return meanConfidence <= confidenceThreshold
    }
}

/// Presentation-only grouping. Recognition windows remain separate evidence
/// for persistence, confidence and overlap repair, while adjacent passages by
/// one speaker read as a natural turn instead of timer-shaped cards.
struct MeetingTranscriptPresentationGroup: Sendable, Equatable {
    private(set) var rows: [MeetingTranscriptRow]

    init(row: MeetingTranscriptRow) { rows = [row] }

    var source: MeetingAudioSource { rows[0].source }
    var speakerID: String { rows[0].speakerID }
    var speaker: String { rows[0].speaker }
    var startFrame: Int64 { rows[0].startFrame }
    var endFrame: Int64 { rows.map(\.endFrame).max() ?? rows[0].endFrame }
    var recognitionNeedsReview: Bool { rows.contains(where: \.recognitionNeedsReview) }
    var text: String { rows.map(\.text).joined(separator: " ") }

    fileprivate mutating func append(_ row: MeetingTranscriptRow) { rows.append(row) }
}

enum MeetingTranscriptPresentation {
    /// Long uninterrupted monologues are periodically split for scanability,
    /// but never at the recognition window cadence. Uncertain model guesses
    /// get their own card so the warning sits next to the affected text.
    static let maximumGroupFrames: Int64 = 45 * 16_000
    static let maximumGapFrames: Int64 = 2 * 16_000

    static func groups(from rows: [MeetingTranscriptRow]) -> [MeetingTranscriptPresentationGroup] {
        var result: [MeetingTranscriptPresentationGroup] = []
        for row in rows {
            guard var current = result.last else {
                result.append(MeetingTranscriptPresentationGroup(row: row))
                continue
            }
            let sameTurn = current.source == row.source
                && current.speakerID == row.speakerID
                && current.recognitionNeedsReview == row.recognitionNeedsReview
                && row.startFrame <= current.endFrame + maximumGapFrames
                && row.endFrame - current.startFrame <= maximumGroupFrames
            guard sameTurn else {
                result.append(MeetingTranscriptPresentationGroup(row: row))
                continue
            }
            result.removeLast()
            current.append(row)
            result.append(current)
        }
        return result
    }
}

/// Only strips time-aligned token matches that are identical apart from
/// punctuation in adjacent windows of one source. Ambiguous boundaries keep
/// the original text.
struct MeetingTranscriptAssembler: Sendable {
    private(set) var rows: [MeetingTranscriptRow] = []
    private(set) var rawWindows: [MeetingTranscriptWindow] = []

    mutating func append(_ window: MeetingTranscriptWindow) {
        guard window.endFrame >= window.startFrame else { return }
        rawWindows.append(window)
        rebuildRows()
    }

    /// Rebuilding from retained transcript metadata makes late recognition
    /// deterministic without discarding the original arrival order or text.
    private mutating func rebuildRows() {
        var prior: [MeetingAudioSource: MeetingTranscriptWindow] = [:]
        rows = []
        let ordered = rawWindows.enumerated().sorted { lhs, rhs in
            if lhs.element.startFrame != rhs.element.startFrame {
                return lhs.element.startFrame < rhs.element.startFrame
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        for window in ordered {
            appendRendered(window, prior: &prior)
        }
    }

    private mutating func appendRendered(
        _ window: MeetingTranscriptWindow,
        prior: inout [MeetingAudioSource: MeetingTranscriptWindow]
    ) {
        var rendered = window.transcript.text
        if let previous = prior[window.source], previous.startFrame <= window.startFrame,
           previous.endFrame > window.startFrame {
            let a = previous.transcript.tokens
            let b = window.transcript.tokens
            let limit = min(a.count, b.count)
            if limit > 0 {
                for length in stride(from: limit, through: 1, by: -1) {
                    let suffix = a.suffix(length)
                    let prefix = b.prefix(length)
                    let matched = zip(suffix, prefix).allSatisfy { old, new in
                        let oldBoundary = Self.boundaryText(old.text)
                        guard !oldBoundary.isEmpty,
                              oldBoundary == Self.boundaryText(new.text),
                              Self.tokenMatches(old, in: previous.transcript.text),
                              Self.tokenMatches(new, in: window.transcript.text) else { return false }
                        let oldStart = Double(previous.startFrame) / 16000 + old.start
                        let oldEnd = Double(previous.startFrame) / 16000 + old.end
                        let newStart = Double(window.startFrame) / 16000 + new.start
                        let newEnd = Double(window.startFrame) / 16000 + new.end
                        return max(oldStart, newStart) <= min(oldEnd, newEnd) + 0.15
                    }
                    guard matched,
                          let removalEnd = Self.completePrefixEnd(Array(prefix), in: rendered) else { continue }
                    let end = rendered.index(rendered.startIndex, offsetBy: removalEnd)
                    rendered = String(rendered[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        if !rendered.isEmpty {
            rows.append(MeetingTranscriptRow(source: window.source, startFrame: window.startFrame,
                                             endFrame: window.endFrame, text: rendered, original: window.transcript))
        }
        prior[window.source] = window
    }

    private static func tokenMatches(_ token: TranscriptToken, in text: String) -> Bool {
        guard token.range.lowerBound >= 0, token.range.upperBound <= text.count,
              token.range.lowerBound < token.range.upperBound else { return false }
        let begin = text.index(text.startIndex, offsetBy: token.range.lowerBound)
        let end = text.index(text.startIndex, offsetBy: token.range.upperBound)
        return text[begin..<end] == token.text
    }

    private static func completePrefixEnd(_ tokens: [TranscriptToken], in text: String) -> Int? {
        var cursor = 0
        for token in tokens {
            guard token.range.lowerBound >= cursor, tokenMatches(token, in: text) else { return nil }
            let begin = text.index(text.startIndex, offsetBy: cursor)
            let end = text.index(text.startIndex, offsetBy: token.range.lowerBound)
            guard text[begin..<end].allSatisfy({ $0.isWhitespace || $0.isPunctuation }) else { return nil }
            cursor = token.range.upperBound
        }
        guard !tokens.isEmpty else { return nil }
        while cursor < text.count {
            let index = text.index(text.startIndex, offsetBy: cursor)
            let character = text[index]
            guard character.isWhitespace || character.isPunctuation else { break }
            cursor += 1
        }
        return cursor
    }

    private static func boundaryText(_ text: String) -> String {
        String(text.filter { !$0.isPunctuation })
    }
}

/// A Mac without headphones plays the other participants through its speakers,
/// and its microphone hears them. Voice processing cancels most of that; this
/// removes what remains at the transcript level. A microphone row is an echo
/// when at least `matchRatio` of its words were recognised in system audio
/// during the same seconds. The system row keeps those words, so nothing that
/// was said disappears, and a row too short to judge stays.
///
/// On 23.10, 49 of 168 "You" rows were other people's speech heard this way.
enum MeetingEchoFilter {
    static let matchRatio = 0.6
    static let minimumWords = 4
    /// The microphone hears the speakers a few milliseconds late, and the two
    /// sources cut their windows at different pauses.
    static let toleranceFrames: Int64 = 2 * 16_000

    static func removingEcho(from rows: [MeetingTranscriptRow]) -> (rows: [MeetingTranscriptRow], removed: Int) {
        let system = rows.filter { $0.source == .system }
        guard !system.isEmpty else { return (rows, 0) }
        var kept: [MeetingTranscriptRow] = []
        kept.reserveCapacity(rows.count)
        var removed = 0
        for row in rows {
            guard row.source == .microphone else { kept.append(row); continue }
            let words = Self.words(row.text)
            guard words.count >= minimumWords else { kept.append(row); continue }
            var heard = Set<String>()
            for other in system where other.endFrame >= row.startFrame - toleranceFrames
                && other.startFrame <= row.endFrame + toleranceFrames {
                heard.formUnion(Self.words(other.text))
            }
            let matched = words.filter(heard.contains).count
            if Double(matched) / Double(words.count) >= matchRatio {
                removed += 1
            } else {
                kept.append(row)
            }
        }
        return (kept, removed)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
