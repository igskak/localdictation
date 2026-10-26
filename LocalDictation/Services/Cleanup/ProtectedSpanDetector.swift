import Foundation

struct ProtectedSpan: Sendable, Equatable {
    enum Category: String, Sendable, Equatable {
        case number
        case date
        case currency
        case negation
        case glossary
        case entity
    }

    let range: Range<Int>
    let category: Category
    let text: String
}

struct ProtectedSpanDetector: Sendable {
    private static let negations: [SpeechLanguage: Set<String>] = [
        .german: ["nicht", "kein", "keine", "keinen", "nie", "niemals"],
        .english: ["not", "no", "never", "without", "cannot", "can't", "don't", "doesn't", "won't"],
        .russian: ["не", "нет", "ни", "никогда", "без"],
        .ukrainian: ["не", "ні", "ніколи", "без"],
        .spanish: ["no", "nunca", "jamás", "sin", "tampoco"],
        .italian: ["non", "mai", "senza", "neanche", "nemmeno"],
        .french: ["ne", "pas", "jamais", "sans", "aucun", "aucune"],
    ]

    func detect(
        in text: String,
        language: SpeechLanguage,
        glossary: [GlossaryEntry] = []
    ) -> [ProtectedSpan] {
        let words = WordScanner.words(in: text)
        var candidates: [ProtectedSpan] = []

        for word in words {
            let previous = Array(words[max(0, word.index - CriticalTokens.dateContextWindow)..<word.index].map(\.text))
            let upper = min(words.count, word.index + CriticalTokens.dateContextWindow + 1)
            let next = word.index + 1 < upper ? Array(words[(word.index + 1)..<upper].map(\.text)) : []
            let category: ProtectedSpan.Category?
            switch CriticalTokens.category(
                of: word.text,
                language: language,
                precededBy: previous,
                followedBy: next
            ) {
            case .number: category = .number
            case .currency: category = .currency
            case .date: category = .date
            case nil: category = nil
            }
            if let category {
                candidates.append(ProtectedSpan(range: word.range, category: category, text: word.text))
            }
            if Self.negations[language, default: []].contains(word.lowercased) {
                candidates.append(ProtectedSpan(range: word.range, category: .negation, text: word.text))
            }
            // A date/amount/currency token has a stronger, measured meaning
            // than capitalization heuristics. Do not let the broader entity
            // fence mask that category when ranges are identical.
            if category == nil, Self.isEntityCandidate(word, language: language) {
                candidates.append(ProtectedSpan(range: word.range, category: .entity, text: word.text))
            }
        }

        for entry in glossary where entry.language == language {
            let phrases = [entry.normalizedTerm] + (entry.normalizedReplacement.map { [$0] } ?? [])
            for phrase in phrases {
                candidates.append(contentsOf: Self.exactMatches(of: phrase, in: text).map {
                ProtectedSpan(range: $0, category: .glossary, text: String(Array(text)[$0]))
                })
            }
        }

        return Self.nonOverlapping(candidates)
    }

    /// Glossary ranges must also be checked independently when a rule owns a
    /// numeric span: the general non-overlapping list can prefer that number.
    static func overlapsGlossary(_ range: Range<Int>, in text: String,
                                 language: SpeechLanguage, glossary: [GlossaryEntry]) -> Bool {
        glossary.filter { $0.language == language }.contains { entry in
            let phrases = [entry.normalizedTerm] + (entry.normalizedReplacement.map { [$0] } ?? [])
            return phrases.contains { phrase in
                exactMatches(of: phrase, in: text).contains { $0.overlaps(range) }
            }
        }
    }

    static func allows(
        proposed range: Range<Int>,
        protected spans: [ProtectedSpan],
        owningWholeSpan: ProtectedSpan.Category? = nil
    ) -> Bool {
        for span in spans where span.range.overlaps(range) || span.range == range {
            guard owningWholeSpan == span.category, range == span.range else { return false }
        }
        return true
    }

    private static func isEntityCandidate(_ word: TextWord, language: SpeechLanguage) -> Bool {
        guard !word.isSentenceInitial, let first = word.text.first else { return false }
        if word.text.count > 1, word.text.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return true }
        // German capitalizes ordinary nouns, so title case alone is not safe
        // entity evidence there.
        return language != .german && first.isUppercase
    }

    private static func exactMatches(of phrase: String, in text: String) -> [Range<Int>] {
        guard !phrase.isEmpty else { return [] }
        let source = Array(text)
        let needle = Array(phrase.lowercased())
        let folded = Array(text.lowercased())
        // Unicode lowercasing can expand a grapheme (for example some legacy
        // forms of sharp s). Character offsets must continue to address the
        // original string, so skip the unsafe fast path in that rare case.
        guard source.count == folded.count else { return [] }
        guard needle.count <= folded.count else { return [] }
        var matches: [Range<Int>] = []
        for start in 0...(folded.count - needle.count) where Array(folded[start..<(start + needle.count)]) == needle {
            let end = start + needle.count
            let beforeIsWord = start > 0 && (source[start - 1].isLetter || source[start - 1].isNumber)
            let afterIsWord = end < source.count && (source[end].isLetter || source[end].isNumber)
            if !beforeIsWord, !afterIsWord { matches.append(start..<end) }
        }
        return matches
    }

    private static func nonOverlapping(_ spans: [ProtectedSpan]) -> [ProtectedSpan] {
        let ordered = spans.sorted {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            return $0.range.count > $1.range.count
        }
        var accepted: [ProtectedSpan] = []
        for span in ordered {
            guard !accepted.contains(where: { $0.range.overlaps(span.range) || $0.range == span.range }) else { continue }
            accepted.append(span)
        }
        return accepted
    }
}
