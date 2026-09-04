# Phase 2 — transcription benchmark and raw dictation

## Objective

Turn a bounded in-memory utterance into a raw transcript carrying token-level timing and confidence, and show that transcript inside Witness.

Phase 2 extends the Phase 1 slice by exactly one stage:

```text
⌥Space release → completed utterance → local transcription → raw transcript + token metadata → shown in-app
```

Phase 2 ends before risk detection, cleanup, and insertion into other applications.

## Explicit non-goals

- Risk highlighting, entity/number rules, glossary, confidence calibration UI (Phase 3).
- Conservative cleanup and edit mapping (Phase 3).
- Accessibility insertion and clipboard fallback (Phase 4).
- Licensing, trial, paywall, Stripe, telemetry, updater (Phase 5).
- Translation, persistent transcript history, cloud inference.

The only way text may leave the app in Phase 2 is an explicit user copy action.

## Engine selection is a benchmark result, not an assumption

No engine may be integrated as the baseline before it is measured against the alternatives.

### Candidate admission requirements

A candidate is only admitted to the benchmark if it satisfies all of:

- Fully local inference on Apple Silicon, with no network access at transcription time.
- German, English, Russian, and Ukrainian.
- Word- or token-level timestamps **and** a usable per-unit confidence or probability signal. An engine that returns only a flat string cannot support the Phase 3 risk engine, and therefore cannot support the product promise. This disqualifies it regardless of its accuracy.
- Deployment target macOS 14.4 per `AGENTS.md`. A candidate that requires a newer macOS is not automatically rejected, but the deployment-target cost must be recorded as an explicit trade-off and decided deliberately — never adopted silently.
- A license compatible with paid direct distribution. Per `AGENTS.md`, the license and the rationale for any third-party dependency must be documented before the dependency is added.

### Benchmark protocol

- A fixed evaluation corpus per language, stored in a git-ignored local directory. Corpus audio is never committed and never leaves the machine.
- Accuracy metrics: WER and CER, computed per language profile.
- Product-critical metrics, reported separately from WER because they are what the product actually promises:
  - numeral, date, and currency error rate;
  - named-entity error rate;
  - confidence calibration — whether low confidence actually correlates with wrong tokens.
- Performance metrics: real-time factor, end-of-speech to usable-transcript latency, peak memory, and model size on disk.
- Every result records the exact corpus, model revision, engine version, and machine it was measured on.
- Results are written to `docs/PHASE_2_BENCHMARK.md`.

A benchmark that reports only WER has not answered the Phase 2 question. Confidence calibration is the deciding metric, because Phase 3 depends on it.

## Required behavior

### Transcription boundary

- A `TranscriptionService` protocol with injected implementations, following the Phase 1 service pattern.
- Inference runs off the main actor and never blocks UI. The coordinator stays `@MainActor`.
- Transcription is cancellable; a cancelled or superseded request must not deliver a result.
- Model availability is explicit state — unavailable, preparing, ready, failed — not an implicit precondition.
- Failure is recoverable and never destroys the captured utterance.

### Transcript model

- The raw transcript is stored verbatim and is never edited in Phase 2.
- Tokens carry: text, character range within the raw transcript, start and end time relative to the utterance, and confidence.
- The character range is what Phase 3 will map risky spans through, so it must be correct on multi-byte text — Cyrillic and German umlauts are the normal case here, not an edge case.
- The language profile that actually produced the transcript is part of the result.

### Language profiles

- Explicit user-selected profiles, not a promise of arbitrary four-language detection per utterance.
- Single-language profiles: `de`, `en`, `ru`, `uk`.
- Priority mixed profiles from `docs/PRODUCT_SCOPE.md`: DE+EN, RU+UK, RU+EN, UK+EN.
- The selected profile is passed to the engine explicitly.

### Recording lifecycle

- The state machine gains transcription states after `.finishing`, and returns to `.ready` when the transcript is delivered or the failure is acknowledged.
- Illegal transitions are rejected rather than silently applied, as in Phase 1.
- A transcription failure surfaces actionable UI and leaves the app usable.

### Raw transcript UI

- The raw transcript is displayed inside Witness only.
- An explicit copy action is available. Nothing is written anywhere without a user action.
- Token confidence may be visualized in the developer diagnostics section only. Phase 2 shows confidence as a measurement, never as a risk verdict.

### Model assets

If the chosen engine requires downloadable weights:

- The download is an explicit user action, never automatic at launch.
- It is resumable and checksum-verified.
- Weights are stored in Application Support, outside the app bundle, and the location is visible to the user.
- This is the only network access Phase 2 introduces. It transmits no content: no audio, no text, no identifiers beyond what fetching a static asset requires.

## Acceptance criteria

- The app builds and tests successfully with the repository's Xcode project under Swift 6 complete concurrency, without warnings.
- Holding `⌥Space`, speaking, and releasing produces a raw transcript visible in the app, verified in all four supported languages.
- Token timings and confidences are populated, and are unit-tested against a fake engine without requiring a model or a microphone.
- Transcription runs off the main actor and the menu bar UI stays responsive during inference.
- Cancelling or superseding a transcription delivers no stale result.
- Audio is still never written to disk during normal operation, and transcripts are memory-only.
- No text is inserted into any other application.
- No analytics, licensing, or Stripe code is introduced.
- The benchmark is recorded in `docs/PHASE_2_BENCHMARK.md`, covering at least two admitted candidates across all four languages, including confidence calibration.
- The chosen engine's license and the rationale for adopting it are documented, per `AGENTS.md`.
- Any deployment-target change is an explicit, recorded decision.

## Completion report

The implementer must report:

- the files and architecture introduced;
- the benchmark results and the engine decision they support;
- commands run and their results;
- manual dictation checks performed, per language;
- known hardware or macOS limitations;
- any acceptance criterion that remains unverified.
