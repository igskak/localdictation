import Foundation

/// Ephemeral offsets into the unmodified raw transcript, measured in Characters.
struct CleanupTokenTiming: Sendable, Equatable {
    let rawRange: Range<Int>
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
    /// True only with explicit engine provenance that a segment boundary
    /// precedes this token. Timestamps alone cannot establish that fact.
    var segmentBoundaryBefore: Bool = false
}

struct CleanupTimingEvidence: Sendable, Equatable {
    let tokens: [CleanupTokenTiming]

    /// Reject the whole sequence if any anchor or timestamp is invalid.
    static func validated(_ tokens: [CleanupTokenTiming], raw: String) -> Self? {
        guard !tokens.isEmpty else { return nil }
        var previousEnd = 0
        var previousStartTime: TimeInterval = 0
        var previousEndTime: TimeInterval = 0
        for token in tokens {
            guard token.rawRange.lowerBound >= previousEnd,
                  token.rawRange.lowerBound >= 0,
                  !token.rawRange.isEmpty,
                  token.rawRange.upperBound <= raw.count,
                  token.start.isFinite, token.end.isFinite,
                  token.start >= 0, token.start <= token.end,
                  token.start >= previousStartTime, token.end >= previousEndTime,
                  token.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true
            else { return nil }
            previousEnd = token.rawRange.upperBound
            previousStartTime = token.start
            previousEndTime = token.end
        }
        return Self(tokens: tokens)
    }

    static func validated(transcript: Transcript) -> Self? {
        let characters = Array(transcript.text)
        guard transcript.tokens.allSatisfy({ token in
            token.range.lowerBound >= 0 && token.range.upperBound <= characters.count
                && token.range.lowerBound < token.range.upperBound
                && String(characters[token.range]) == token.text
        }) else { return nil }
        return validated(transcript.tokens.map {
            CleanupTokenTiming(rawRange: $0.range, start: $0.start, end: $0.end, confidence: $0.confidence)
        }, raw: transcript.text)
    }
}
