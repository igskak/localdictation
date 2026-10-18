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
    var speaker: String { source == .microphone ? "You" : "Others" }
}

/// Only strips exact, time-aligned token matches from adjacent overlapping
/// windows of the same source. Ambiguous boundaries keep the original text.
struct MeetingTranscriptAssembler: Sendable {
    private var prior: [MeetingAudioSource: MeetingTranscriptWindow] = [:]
    private(set) var rows: [MeetingTranscriptRow] = []
    private(set) var rawWindows: [MeetingTranscriptWindow] = []

    mutating func append(_ window: MeetingTranscriptWindow) {
        guard window.endFrame >= window.startFrame else { return }
        rawWindows.append(window)
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
                        guard old.text == new.text,
                              Self.tokenMatches(old, in: previous.transcript.text),
                              Self.tokenMatches(new, in: window.transcript.text) else { return false }
                        let oldStart = Double(previous.startFrame) / 16000 + old.start
                        let oldEnd = Double(previous.startFrame) / 16000 + old.end
                        let newStart = Double(window.startFrame) / 16000 + new.start
                        let newEnd = Double(window.startFrame) / 16000 + new.end
                        return max(oldStart, newStart) <= min(oldEnd, newEnd) + 0.15
                    }
                    guard matched, let last = prefix.last,
                          Self.isCompletePrefix(Array(prefix), in: rendered) else { continue }
                    let end = rendered.index(rendered.startIndex, offsetBy: last.range.upperBound)
                    rendered = String(rendered[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        if !rendered.isEmpty {
            rows.append(MeetingTranscriptRow(source: window.source, startFrame: window.startFrame,
                                             endFrame: window.endFrame, text: rendered, original: window.transcript))
            rows.sort { lhs, rhs in lhs.startFrame < rhs.startFrame }
        }
        if prior[window.source].map({ $0.startFrame <= window.startFrame }) ?? true {
            prior[window.source] = window
        }
    }

    private static func tokenMatches(_ token: TranscriptToken, in text: String) -> Bool {
        guard token.range.lowerBound >= 0, token.range.upperBound <= text.count,
              token.range.lowerBound < token.range.upperBound else { return false }
        let begin = text.index(text.startIndex, offsetBy: token.range.lowerBound)
        let end = text.index(text.startIndex, offsetBy: token.range.upperBound)
        return text[begin..<end] == token.text
    }

    private static func isCompletePrefix(_ tokens: [TranscriptToken], in text: String) -> Bool {
        var cursor = 0
        for token in tokens {
            guard token.range.lowerBound >= cursor, tokenMatches(token, in: text) else { return false }
            let begin = text.index(text.startIndex, offsetBy: cursor)
            let end = text.index(text.startIndex, offsetBy: token.range.lowerBound)
            guard text[begin..<end].allSatisfy(\.isWhitespace) else { return false }
            cursor = token.range.upperBound
        }
        return !tokens.isEmpty
    }
}
