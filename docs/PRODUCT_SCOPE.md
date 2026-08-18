# Product scope

## Product promise

LocalDictation is a local-first dictation utility for people who write substantial work text on a Mac. It should save time without hiding uncertainty: numbers, names, terms, and low-confidence fragments must be reviewable before they become silent errors.

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

## MVP language scope

Supported speech languages:

- German (`de`)
- English (`en`)
- Russian (`ru`)
- Ukrainian (`uk`)

Priority mixed-language combinations:

- German and English
- Russian and Ukrainian
- Russian and English
- Ukrainian and English

The app should use explicit language profiles rather than promise arbitrary four-language detection in every utterance.

## MVP product scope

- Global push-to-talk and toggle recording modes.
- Local microphone capture and VAD.
- Local STT.
- Raw transcript and conservative cleanup.
- Risk detection for low-confidence fragments, numbers, dates, currency, names, negations, and glossary terms.
- Review UI that appears only when useful and always runs before insertion into the target application.
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
- Polish language support.

## Commercial assumptions

- Fourteen-day full trial.
- EUR 99 lifetime as the primary launch offer.
- EUR 49 annual as the secondary offer.
- The exact lifetime update policy must be decided before checkout implementation. Current recommendation: permanent use of the purchased major version and all of its minor updates.

## Privacy and telemetry boundary

- Audio, transcripts, vocabulary, clipboard contents, target-application contents, risky fragments, and other content-derived data never leave the Mac.
- Audio remains memory-only through the active dictation and, when needed, the review step; it is discarded after insertion or dismissal.
- Limited non-content product and marketing events may be sent for activation, funnel measurement, licensing, checkout, and updates. The allowed event names and payload fields must be enumerated before implementation.
- General diagnostics remain local unless the user explicitly chooses to share them.
- The privacy policy, first-run disclosure, and relevant product terms must identify every transmitted field, purpose, recipient, and retention period.
