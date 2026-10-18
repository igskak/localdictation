import Foundation

struct ContextCompositor: Sendable {
    func transform(
        _ text: String,
        raw: String,
        language: SpeechLanguage,
        context: DictationTextContext,
        glossary: [GlossaryEntry]
    ) -> CleanupResult {
        var result = CleanupResult.unchanged(text, language: language)

        if shouldLowercaseFirstLetter(text: result.cleaned, raw: raw, context: context, glossary: glossary),
           let offset = firstLetterOffset(in: result.cleaned) {
            let characters = Array(result.cleaned)
            let replacement = String(characters[offset]).lowercased()
            result = append(
                CleanupTransformation.apply(
                    [.init(range: offset..<(offset + 1), text: replacement, kind: .contextCapitalization)],
                    to: result.cleaned,
                    language: language
                ),
                to: result
            )
        }

        if shouldDropTerminalPeriod(from: result.cleaned, context: context) {
            let end = result.cleaned.count
            result = append(
                CleanupTransformation.apply(
                    [.init(range: (end - 1)..<end, text: "", kind: .contextPunctuation)],
                    to: result.cleaned,
                    language: language
                ),
                to: result
            )
        }

        if !context.hasSelection,
           let preceding = context.textBeforeCaret.last,
           InsertionSpacing.prefix(forCharacterBefore: preceding, text: result.cleaned) == " " {
            result = append(
                CleanupTransformation.apply(
                    [.init(range: 0..<0, text: " ", kind: .contextSpacing)],
                    to: result.cleaned,
                    language: language
                ),
                to: result
            )
        }
        return result
    }

    private func shouldLowercaseFirstLetter(
        text: String,
        raw: String,
        context: DictationTextContext,
        glossary: [GlossaryEntry]
    ) -> Bool {
        guard !context.hasSelection,
              isSentenceContinuation(context.textBeforeCaret),
              let rawFirst = raw.first(where: \.isLetter), rawFirst.isLowercase,
              let cleanFirst = text.first(where: \.isLetter), cleanFirst.isUppercase
        else { return false }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return !glossary.contains { entry in
            folded.hasPrefix(entry.term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
    }

    private func isSentenceContinuation(_ before: String) -> Bool {
        guard let last = before.last(where: { !$0.isWhitespace }) else { return false }
        return !last.isNewline && ![".", "?", "!"].contains(last)
    }

    private func shouldDropTerminalPeriod(from text: String, context: DictationTextContext) -> Bool {
        guard text.last == "." else { return false }
        if context.textAfterCaret.first(where: { !$0.isWhitespace }) == "." { return true }
        guard context.category.dropsShortTerminalPeriod,
              text.count <= 120,
              !text.contains("\n"),
              !text.dropLast().contains(where: { $0 == "." || $0 == "?" || $0 == "!" })
        else { return false }
        return true
    }

    private func firstLetterOffset(in text: String) -> Int? {
        Array(text).firstIndex(where: \.isLetter)
    }

    private func append(_ stage: CleanupResult, to accumulated: CleanupResult) -> CleanupResult {
        EditMapComposition.append(stage, to: accumulated) ?? accumulated
    }
}

