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
