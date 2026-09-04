# Product scope

## Product promise

Witness is a local-first dictation utility for people who write substantial work text on a Mac. It should save time without hiding uncertainty: numbers, names, terms, and low-confidence fragments must be reviewable before they become silent errors.

The messaging hierarchy is:

1. Speak instead of typing and save time.
2. See the fragments that are worth checking.
3. Keep speech and text local on the Mac.
4. Buy the product once instead of depending on a cloud subscription.

## Initial market

- Geography: Germany.
- Primary user: an individual knowledge worker who writes tasks, ticket comments, email, documentation, or AI prompts on a Mac.
- Distribution: direct download from the product website.
- Payments: Stripe Managed Payments, with Stripe acting as Merchant of Record, subject to account availability and product eligibility before checkout implementation.
- No Mac App Store dependency in the MVP.

## Language scope

The user names the languages they speak, once, at first run, choosing from every language the speech engine knows. There are two tiers and the difference is visible in the picker:

- **Verified** — German (`de`), English (`en`), Russian (`ru`), Ukrainian (`uk`). Recognition, conservative cleanup, and every risk signal, measured in `docs/PHASE_2_BENCHMARK.md` and `docs/PHASE_3_MEASUREMENT.md`. The initial market is Germany, so German and English are what a fresh install starts with.
- **Available** — every other language the engine carries. Recognition, plus the rules that rest on nothing this product had to measure. Filler removal, the malformed-word rule, and the letter-level language evidence stay off rather than fire on a language nobody checked.

The selection is explicit and ordered: the first language is preferred, and it decides a phrase too short for the engine to be sure about. Every utterance is decoded as one of the selected languages and never as one that was not selected. The app does not promise to hear an arbitrary mixture of them inside a single utterance — one utterance is one language, chosen from the engine's own ranking. See `docs/PHASE_7.md`.

## MVP product scope

- A first-run language selection, changeable at any time, plus a temporary pin to one of the selected languages.
- Global push-to-talk and toggle recording modes.
- Local microphone capture and VAD.
- Local STT.
- Raw transcript and conservative cleanup.
- Risk detection for low-confidence fragments, numbers, dates, currency, names, malformed words, negations, and glossary terms.
- Review UI that never stands between the user and their text. Insertion is unconditional; when something is worth checking the app lights an indicator, and the review opens only if the user asks for it.
- Raw transcript recovery.
- Ephemeral replay of a risky audio fragment.
- Accessibility insertion with clipboard fallback.
- User dictionaries scoped by language.
- Email-key activation for up to two Macs without a product account. Download is never gated, but email activation is required after the initial five dictations or 24 hours from the first successful dictation, whichever comes first, to continue the trial.

## Deliberately after MVP

- Translation.
- Aggressive rewriting and style presets.
- Team accounts.
- Windows support.
- Persistent recording history by default.
- Cloud inference.
- Polish, or any other language, in the verified tier: a corpus, filler and title tables, and a measured false-warning rate. Polish is recognized today; it is not measured.

## Commercial assumptions

- Fourteen-day full trial.
- EUR 99 lifetime as the primary launch offer.
- EUR 49 annual as the secondary offer.
- The exact lifetime update policy must be decided before checkout implementation. Current recommendation: permanent use of the purchased major version and all of its minor updates.

## Privacy and telemetry boundary

- Audio, transcripts, vocabulary, clipboard contents, target-application contents, risky fragments, and other content-derived data never leave the Mac.
- Audio remains memory-only through the active dictation and, when a result is worth checking, until the review is closed, declined, or superseded by the next utterance; it is discarded at whichever of those comes first, and immediately when nothing is worth checking.
- Limited non-content product and marketing events may be sent for activation, funnel measurement, licensing, checkout, and updates. The allowed event names and payload fields must be enumerated before implementation.
- General diagnostics remain local unless the user explicitly chooses to share them.
- The privacy policy, first-run disclosure, and relevant product terms must identify every transmitted field, purpose, recipient, and retention period.
