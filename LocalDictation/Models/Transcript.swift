import Foundation

/// One recognized unit — a word for most engines, a sub-word piece for some.
///
/// The range is stored as `Character` offsets rather than `String.Index` so a
/// token stays meaningful when it is encoded for a benchmark report or compared
/// in a test. `resolvedRange(in:)` converts it back for display.
struct TranscriptToken: Sendable, Equatable, Codable {
    let text: String
    /// Character offsets into the owning `Transcript.text`.
    let range: Range<Int>
    /// Seconds from the start of the utterance.
    let start: TimeInterval
    let end: TimeInterval
    /// Engine-reported confidence in `0...1`.
    ///
    /// `nil` means the engine exposes no confidence signal at all — which is a
    /// disqualifying property for this product, not a detail. Phase 3's risk
    /// engine has nothing to work with when this is always `nil`.
    let confidence: Double?

    var duration: TimeInterval { max(end - start, 0) }
}

/// The raw result of local transcription.
///
/// Phase 2 never edits `text`: cleanup and risk marking belong to Phase 3. The
/// text and tokens stay in memory and are only released to the user through an
/// explicit copy action.
struct Transcript: Sendable, Equatable, Codable {
    let text: String
    let tokens: [TranscriptToken]
    /// The profile the user selected and the engine was asked to use.
    let profile: LanguageProfile
    /// What the engine reported actually recognizing, when it reports anything.
    let detectedLanguage: SpeechLanguage?
    /// Length of the source audio.
    let audioDuration: TimeInterval
    /// Wall-clock inference time, for diagnostics and the benchmark.
    let processingDuration: TimeInterval
    let engineIdentifier: String

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Inference time relative to audio length. Below 1.0 is faster than real time.
    var realTimeFactor: Double? {
        audioDuration > 0 ? processingDuration / audioDuration : nil
    }

    /// Whether this engine produced any confidence signal at all.
    var hasConfidenceSignal: Bool {
        tokens.contains { $0.confidence != nil }
    }

    var meanConfidence: Double? {
        let values = tokens.compactMap(\.confidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var minimumConfidence: Double? {
        tokens.compactMap(\.confidence).min()
    }

    /// Tokens whose confidence falls at or below `threshold`. Phase 2 only
    /// measures this; deciding what it *means* is Phase 3's job.
    func tokens(atOrBelow threshold: Double) -> [TranscriptToken] {
        tokens.filter { ($0.confidence ?? 1) <= threshold }
    }

    /// Converts a token's character offsets into indices usable on `text`.
    /// Returns `nil` rather than trapping when a token does not fit the text.
    func resolvedRange(for token: TranscriptToken) -> Range<String.Index>? {
        let count = text.count
        guard token.range.lowerBound >= 0,
              token.range.upperBound <= count,
              token.range.lowerBound <= token.range.upperBound,
              let lower = text.index(text.startIndex, offsetBy: token.range.lowerBound, limitedBy: text.endIndex),
              let upper = text.index(text.startIndex, offsetBy: token.range.upperBound, limitedBy: text.endIndex)
        else { return nil }
        return lower..<upper
    }

    static func empty(profile: LanguageProfile, engineIdentifier: String) -> Transcript {
        Transcript(
            text: "",
            tokens: [],
            profile: profile,
            detectedLanguage: nil,
            audioDuration: 0,
            processingDuration: 0,
            engineIdentifier: engineIdentifier
        )
    }
}

extension Transcript {
    /// One timed word as an engine reports it, before it is placed into a string.
    struct Word: Sendable, Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Double?

        init(_ text: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
        }
    }

    /// Builds a transcript from timed words, joining them with `separator` and
    /// computing each token's character range from the assembled text.
    ///
    /// Most engines hand back words without offsets into a final string, so the
    /// offsets have to be derived exactly once, here, instead of at every call
    /// site. Counting in `Character`s keeps umlauts and Cyrillic correct.
    static func assemble(
        words: [Word],
        separator: String = " ",
        profile: LanguageProfile,
        detectedLanguage: SpeechLanguage? = nil,
        audioDuration: TimeInterval,
        processingDuration: TimeInterval,
        engineIdentifier: String
    ) -> Transcript {
        var text = ""
        var offset = 0
        var tokens: [TranscriptToken] = []
        tokens.reserveCapacity(words.count)

        let separatorLength = separator.count

        for word in words where !word.text.isEmpty {
            if !text.isEmpty {
                text += separator
                offset += separatorLength
            }
            let length = word.text.count
            text += word.text
            tokens.append(
                TranscriptToken(
                    text: word.text,
                    range: offset..<(offset + length),
                    start: word.start,
                    end: word.end,
                    confidence: word.confidence
                )
            )
            offset += length
        }

        return Transcript(
            text: text,
            tokens: tokens,
            profile: profile,
            detectedLanguage: detectedLanguage,
            audioDuration: audioDuration,
            processingDuration: processingDuration,
            engineIdentifier: engineIdentifier
        )
    }
}
