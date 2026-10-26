# ES / IT / FR expansion

## Goal

Launch Witness for Spanish-, Italian-, and French-speaking customers without
weakening the product promise: local processing, visible uncertainty, and no
language-dependent guess presented as a verified result.

## Current slice — completed

### Product verification

- Spanish (`es-ES`), Italian (`it-IT`), and French (`fr-FR`) have a separate
  **risk-calibrated** tier.
- The review engine marks digits, currency, spelled-out numbers, dates, titled
  names, glossary near-misses, and malformed words in all three languages.
- Conservative filler tables and protected negation vocabularies exist per
  language.
- A committed correct-text corpus measures false-warning density, indicator
  rate, and semantic preservation per language. The gate is ≤ 6 marks per 100
  correct words, ≤ 25% of ordinary samples lighting the indicator, and 100%
  semantic preservation.
- Advanced cleanup remains off. The four end-to-end verified languages remain
  DE/EN/RU/UK until ES/IT/FR have recorded speech and measured recognition.

### Paid-entry funnel

The first localized web slice is the paid 14-day offer, including the pages a
buyer needs before and after payment:

| Market | Offer | Thank-you | Cancellation |
| --- | --- | --- | --- |
| ES | `/es/start` | `/es/start/gracias` | `/es/cancelar-suscripcion` |
| IT | `/it/start` | `/it/start/grazie` | `/it/annulla-abbonamento` |
| FR | `/fr/start` | `/fr/start/merci` | `/fr/resilier-abonnement` |

Each offer repeats the complete price and renewal sentence beside the primary
CTA and in the pricing section. Each funnel includes a no-JavaScript
cancellation form, localized cookie consent, language switching, `lang`, and
`noindex` metadata. New-market pages link to the existing English legal set and
say so explicitly.

## Release gates before paid acquisition

The routes may be tested now, but campaigns in ES/IT/FR stay off until all of
these are true:

1. A native reviewer signs off the commercial copy, cancellation wording, UI
   truncation, and tone for each market.
2. Counsel-approved translations of terms, withdrawal information, privacy,
   legal notice, and licence terms replace the English fallback. This plan is
   not a legal-compliance opinion.
3. Stripe checkout, receipts, renewal notices, cancellation mail, and payment
   methods are verified in the buyer's language and currency presentation.
4. One complete test purchase per locale proves: offer → Stripe → return page →
   download → email activation → portal → cancellation confirmation.
5. Mobile and desktop visual QA passes at 320, 375, 768, 1280, and 1440 px,
   including keyboard focus, 200% zoom, and reduced motion.

## Next slices

### 1. App localization

- Add ES/IT/FR localizations to `Localizable.xcstrings` and
  `InfoPlist.xcstrings`; do not translate language names manually where
  `Locale` already supplies them.
- Localize first run, menu bar, recording states, review reasons, settings,
  permissions, licensing, paywall, diagnostics, updater, and all error paths.
- Use locale-aware number, date, currency, and plural formatting. Keep stable
  telemetry event names, file keys, language codes, and licence payloads
  untranslated.
- Add layout snapshots for the longest strings and VoiceOver labels. Native
  review is required before changing the app's supported-localization list.

### 2. Recorded-language verification

- Record consented ES/IT/FR corpora with amounts, dates, names, negation,
  accents, technical vocabulary, quiet speech, and mixed-language utterances.
- Measure WER/CER, numeric error rate, critical-error recall, dropped critical
  words, false warnings, and cleanup semantic preservation per language.
- Tune only from corpus failures. Promotion into `verifiedCodes` requires the
  same release gates as DE/EN/RU/UK; it is never a flag-only change.

### 3. Main landing and support pages

- Localize the main landing, download handoff, pricing, FAQ, comparison hub,
  product comparisons, update/release notes, help, and contact responses.
- Give each locale its own canonical URL and reciprocal `hreflang`; keep
  automatic browser-language redirects off.
- Localize screenshots and demo transcripts so visible product examples match
  the page language and the actual calibrated feature set.

### 4. Lifecycle and operations

- Localize activation, renewal, cancellation, refund, failed-payment, and
  support email templates in `Service/` without adding content-derived data.
- Add locale as explicit non-content metadata only where it is needed to select
  a template, and disclose that field wherever the service payload is listed.
- Prepare native-language support macros and a glossary for Witness terms so
  site, app, email, and support use the same vocabulary.

## Measurement after launch

Report the paid funnel separately for ES, IT, and FR: paid-entry view → checkout
click → purchase → activation → day-15 renewal → cancellation/refund. Locale is
acceptable product metadata; audio, transcript, vocabulary, clipboard, app
contents, and highlighted fragments remain strictly local and must never enter
analytics.
