import Foundation

/// Cleanup as a set of non-overlapping replacements over the raw text.
///
/// Building one sorted replacement list and applying it in a single pass is
/// what makes the edit map exact: the cleaned string and the map are produced
/// by the same walk, so a range can never drift out of sync with the text it
/// describes. Rewriting the string repeatedly and diffing afterwards would
/// reconstruct the map by guesswork.
struct ConservativeCleanupService: CleanupService {
    /// Interjections that are never content words in their language.
    ///
    /// The lists are short because the cost of the two mistakes is not
    /// symmetric. Missing a filler leaves an "ähm" in the text, which the user
    /// sees and can delete. Deleting a real word — Russian «ну», «вот», «типа»
    /// all carry meaning in ordinary sentences — silently changes what they
    /// said, which is precisely the failure this product exists to prevent.
    static let fillers: [SpeechLanguage: Set<String>] = [
        .german: ["äh", "ähm", "öhm", "hm", "hmm", "mhm"],
        .english: ["uh", "uhm", "um", "erm", "hmm", "mhm"],
        .russian: ["ээ", "эээ", "эм", "ммм", "мм"],
        .ukrainian: ["ее", "еее", "ем", "ммм", "мм"],
    ]

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    /// Punctuation that closes what precedes it, so a space in front of it is
    /// a recognition artifact. Quotation marks are excluded on purpose: German
    /// writes an opening quote as `»`, and no rule here can tell which end of a
    /// pair a given mark is.
    private static let closingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", "…"]

    private struct Replacement {
        let range: Range<Int>
        let text: String
        let kind: TextEdit.Kind
    }

    func clean(_ raw: String, language: SpeechLanguage, options: CleanupOptions) -> CleanupResult {
        let characters = Array(raw)
        guard !characters.isEmpty else { return .unchanged(raw, language: language) }

        let words = WordScanner.words(in: raw)
        var replacements: [Replacement] = []

        // Order matters only in that earlier rules claim their characters
        // first; `accept` refuses anything that overlaps an accepted range, so
        // two rules can never both rewrite the same character.
        var claimed: [Range<Int>] = []

        func accept(_ replacement: Replacement) {
            guard !claimed.contains(where: { $0.overlaps(replacement.range) || ($0 == replacement.range) }) else { return }
            guard String(characters[replacement.range]) != replacement.text else { return }
            replacements.append(replacement)
            claimed.append(replacement.range)
        }

        let removedWordIndices: Set<Int>
        if options.removesFillers {
            let removals = Self.fillerRemovals(characters: characters, words: words, language: language)
            removedWordIndices = Set(removals.map(\.wordIndex))
            for removal in removals { accept(removal.replacement) }
        } else {
            removedWordIndices = []
        }

        if options.fixesPunctuationSpacing {
            for replacement in Self.punctuationSpacing(characters: characters) { accept(replacement) }
        }

        if options.collapsesWhitespace {
            for replacement in Self.whitespaceCollapsing(characters: characters) { accept(replacement) }
        }

        if options.capitalizesSentences {
            for replacement in Self.sentenceCapitalization(
                characters: characters,
                words: words,
                removed: removedWordIndices
            ) { accept(replacement) }
        }

        if options.addsTerminalPunctuation,
           let replacement = Self.terminalPunctuation(characters: characters) {
            accept(replacement)
        }

        // Insertions sort before replacements that start at the same offset.
        // A period appended at the trimmed end and the trailing space that gets
        // dropped both anchor to the same character; applying the insertion
        // first is what keeps the segment list monotonic.
        let ordered = replacements.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.isEmpty && !$1.range.isEmpty
        }
        return Self.apply(ordered, to: characters, raw: raw, language: language)
    }

    // MARK: - Rules

    private struct FillerRemoval {
        let wordIndex: Int
        let replacement: Replacement
    }

    /// Deletes a filler together with one adjacent space, so removing it does
    /// not leave a double space behind for the whitespace rule to clean up as
    /// a second, unrelated-looking edit.
    private static func fillerRemovals(
        characters: [Character],
        words: [TextWord],
        language: SpeechLanguage
    ) -> [FillerRemoval] {
        guard let vocabulary = fillers[language], !vocabulary.isEmpty else { return [] }

        return words.compactMap { word in
            guard vocabulary.contains(word.lowercased) else { return nil }

            var lower = word.range.lowerBound
            var upper = word.range.upperBound

            if upper < characters.count, characters[upper] == " " {
                upper += 1
            } else if lower > 0, characters[lower - 1] == " " {
                lower -= 1
            }

            return FillerRemoval(
                wordIndex: word.index,
                replacement: Replacement(range: lower..<upper, text: "", kind: .fillerRemoval)
            )
        }
    }

    /// Removes whitespace sitting in front of closing punctuation, and inserts
    /// the missing space after a sentence terminator or comma.
    private static func punctuationSpacing(characters: [Character]) -> [Replacement] {
        var replacements: [Replacement] = []
        var position = 0

        while position < characters.count {
            let character = characters[position]

            if character.isWhitespace {
                var end = position
                while end < characters.count, characters[end].isWhitespace { end += 1 }
                if end < characters.count, closingPunctuation.contains(characters[end]), end > position {
                    replacements.append(Replacement(range: position..<end, text: "", kind: .spacing))
                }
                position = end
                continue
            }

            // "Freitag.Der" -> "Freitag. Der". Requiring a letter after the
            // punctuation is what keeps "1.450" and "12:30" intact: a digit
            // there means this is a number, not a sentence boundary.
            if closingPunctuation.contains(character),
               position + 1 < characters.count,
               characters[position + 1].isLetter {
                replacements.append(
                    Replacement(range: (position + 1)..<(position + 1), text: " ", kind: .spacing)
                )
            }

            position += 1
        }

        return replacements
    }

    /// Collapses runs of whitespace to a single space and trims the ends.
    private static func whitespaceCollapsing(characters: [Character]) -> [Replacement] {
        var replacements: [Replacement] = []
        var position = 0

        while position < characters.count {
            guard characters[position].isWhitespace else {
                position += 1
                continue
            }

            var end = position
            while end < characters.count, characters[end].isWhitespace { end += 1 }

            let isLeading = position == 0
            let isTrailing = end == characters.count
            let replacement = (isLeading || isTrailing) ? "" : " "
            let current = String(characters[position..<end])

            if current != replacement {
                replacements.append(Replacement(range: position..<end, text: replacement, kind: .spacing))
            }
            position = end
        }

        return replacements
    }

    /// Uppercases the first letter of each sentence, and nothing else.
    ///
    /// This rule is deliberately one-directional. German capitalizes every
    /// noun and Russian capitalizes none, so a rule that also *lowercased*
    /// would be right in one language and destructive in the other. Deciding
    /// which German words are nouns needs a tagged model, which is outside a
    /// conservative pass — the engine already does it, and cleanup leaves that
    /// judgement alone.
    private static func sentenceCapitalization(
        characters: [Character],
        words: [TextWord],
        removed: Set<Int>
    ) -> [Replacement] {
        var replacements: [Replacement] = []
        var expectsSentenceStart = true

        for word in words {
            // A filler at the head of a sentence is about to disappear, so the
            // word after it is the one that becomes sentence-initial.
            guard !removed.contains(word.index) else { continue }

            if expectsSentenceStart {
                if let first = word.text.first, first.isLowercase {
                    let uppercased = String(first).uppercased()
                    // "ß".uppercased() is "SS": a rule that changes the length
                    // of a word is no longer a capitalization edit.
                    if uppercased.count == 1 {
                        replacements.append(
                            Replacement(
                                range: word.range.lowerBound..<(word.range.lowerBound + 1),
                                text: uppercased,
                                kind: .capitalization
                            )
                        )
                    }
                }
                expectsSentenceStart = false
            }

            var position = word.range.upperBound
            while position < characters.count, !isWordCharacter(characters[position]) {
                if sentenceTerminators.contains(characters[position]) { expectsSentenceStart = true }
                position += 1
            }
        }

        return replacements
    }

    /// Adds a closing period when the utterance ends mid-air.
    private static func terminalPunctuation(characters: [Character]) -> Replacement? {
        var end = characters.count
        while end > 0, characters[end - 1].isWhitespace { end -= 1 }
        guard end > 0 else { return nil }

        // Only a sentence that runs off the end gets a period. Anything
        // already closed — by punctuation, a quote, a bracket — is left alone,
        // because guessing what belongs after it is not a conservative edit.
        let last = characters[end - 1]
        guard last.isLetter || last.isNumber else { return nil }

        return Replacement(range: end..<end, text: ".", kind: .punctuation)
    }

    // MARK: - Assembly

    /// Applies sorted, non-overlapping replacements, building the cleaned text,
    /// the edit list, and the map in one walk.
    private static func apply(
        _ replacements: [Replacement],
        to characters: [Character],
        raw: String,
        language: SpeechLanguage
    ) -> CleanupResult {
        guard !replacements.isEmpty else { return .unchanged(raw, language: language) }

        var cleaned = ""
        var edits: [TextEdit] = []
        var segments: [EditMap.Segment] = []
        var rawPosition = 0
        var cleanedPosition = 0

        for replacement in replacements {
            // The ordering above makes this hold for every replacement the
            // rules produce; the guard keeps the map monotonic even if a future
            // rule violates it, rather than emitting a segment list that maps
            // ranges to nonsense.
            guard replacement.range.lowerBound >= rawPosition else { continue }

            if replacement.range.lowerBound > rawPosition {
                let carried = String(characters[rawPosition..<replacement.range.lowerBound])
                cleaned += carried
                segments.append(
                    EditMap.Segment(
                        raw: rawPosition..<replacement.range.lowerBound,
                        cleaned: cleanedPosition..<(cleanedPosition + carried.count),
                        isEdit: false
                    )
                )
                cleanedPosition += carried.count
                rawPosition = replacement.range.lowerBound
            }

            let rawText = String(characters[replacement.range])
            let cleanedRange = cleanedPosition..<(cleanedPosition + replacement.text.count)
            cleaned += replacement.text
            segments.append(
                EditMap.Segment(raw: replacement.range, cleaned: cleanedRange, isEdit: true)
            )
            edits.append(
                TextEdit(
                    kind: replacement.kind,
                    rawRange: replacement.range,
                    cleanedRange: cleanedRange,
                    rawText: rawText,
                    cleanedText: replacement.text
                )
            )
            cleanedPosition += replacement.text.count
            rawPosition = replacement.range.upperBound
        }

        if rawPosition < characters.count {
            let carried = String(characters[rawPosition...])
            cleaned += carried
            segments.append(
                EditMap.Segment(
                    raw: rawPosition..<characters.count,
                    cleaned: cleanedPosition..<(cleanedPosition + carried.count),
                    isEdit: false
                )
            )
            cleanedPosition += carried.count
        }

        return CleanupResult(
            raw: raw,
            cleaned: cleaned,
            edits: edits,
            map: EditMap(
                segments: segments,
                rawLength: characters.count,
                cleanedLength: cleanedPosition
            ),
            language: language
        )
    }
}

/// Matches `WordScanner`'s notion of what belongs to a word, so the
/// capitalization rule walks the same boundaries the scanner found.
private func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
}
