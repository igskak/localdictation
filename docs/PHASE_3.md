# Phase 3 — uncertainty and conservative cleanup

## Objective

Turn a raw transcript into a result the user can trust without re-reading every
word: clean it conservatively, mark the fragments worth checking, and show a
review step when — and only when — it earns the interruption.

```text
raw transcript + token timings
  -> conservative cleanup with an auditable edit map
  -> risk signals over the raw text
  -> risky spans mapped onto the cleaned text
  -> ReviewCoordinator decision
       -> nothing worth saying: done, no interruption
       -> something worth saying: review strip with risky spans,
          raw transcript recovery, and memory-only audio replay
```

Phase 3 ends before insertion into other applications. The result stays inside
LocalDictation.

## Explicit non-goals

- Accessibility insertion, clipboard fallback, app compatibility (Phase 4).
- Licensing, trial, paywall, telemetry, updater (Phase 5).
- Translation, style presets, aggressive rewriting — these are post-MVP by
  `docs/PRODUCT_SCOPE.md` and must not creep in under the name "cleanup".
- Persistent history. Transcripts and audio stay memory-only.

## Build order: rules first, confidence last

`docs/ARCHITECTURE.md` defines the risk engine as a combination of six signals:
model confidence, language switching, entities, numbers, glossary matches, and
cleanup edits. Five of those are deterministic functions over text and need no
model at all.

**Build those five first, and treat model confidence as a sixth input added
behind a weight that starts at zero.**

Three reasons, in order of weight:

1. **The deterministic signals are the ones that carry the promise.** Amounts,
   dates, currency, and names are where an error is expensive. "This is a number"
   is a fact about the text, not a probability.
2. **They are testable without a model.** Pure functions, deterministic tests, no
   1.5 GB of weights and no 20-minute benchmark run in the loop.
3. **The Phase 2 measurement argues for it.** Whisper's word probabilities showed
   weak separation between correct and incorrect tokens, and *negative*
   separation on Russian, on a small synthesized corpus. That is not yet a
   verdict, but it is reason enough not to make the whole feature rest on it.

The architecture does not change. Confidence joins as one more signal once it has
been measured on real speech, and its weight is a tuned parameter rather than a
structural assumption.

## What no risk engine can catch, and why the app does not chase it

A dropped negation. If the engine swallows "не" or "nicht", the word is simply
not in the text: no rule can flag what is absent, and no confidence score
attaches to a token that was never emitted.

**Decided 2026-08-19: the app does not build a mechanism for this. The user
catches it by reading.** The reasoning, recorded so it is not re-opened without
new evidence:

Memory for digits and memory for meaning are not the same thing. Reading back
"we will ship before April 15th" when you meant "will not" is your own thought
turned inside out, seconds after you formed it — that is close to the easiest
class of error for a person to catch on a scan. Reading back "1415" when you
said "1450" is the opposite: digits leave almost no episodic trace, and no
amount of re-reading recovers which one you actually spoke.

So the mechanism earns its place exactly where the risk signals already fire —
numbers, amounts, names — and is least needed where they do not. This is
dictation, not transcription of someone else's recording: the speaker has the
intent in working memory, and the product's first promise is saving time, not
inviting a proofread.

Consequences:

- **Audio replay is offered only for a flagged span**, inside the review strip.
- **Audio is discarded as soon as the review decision is "no review needed."**
  This is strictly better for privacy and memory than keeping it reachable: the
  recording's lifetime ends at the decision rather than at the end of the
  interaction.
- **Raw transcript recovery lives inside review too.** It needs no separate
  affordance: any cleanup edit is itself a risk signal, so a transcript the app
  meaningfully changed always produces a review. If no risk fired, the raw and
  cleaned texts do not differ in any way worth showing.

If calibration later turns out usable, a dropped word sometimes leaves a trace
at the join — a timing gap or a low-probability boundary. That is a hypothesis to
test against measured data, not a feature to plan.

## Required behavior

### Conservative cleanup

- A `CleanupService` protocol with an injected implementation.
- Every edit is recorded: its range in the raw text, its range in the cleaned
  text, and its kind (punctuation, capitalization, filler removal, spacing).
- The raw transcript is never mutated. It remains recoverable at any point.
- Cleanup is **conservative by definition**: it may not change wording, word
  order, numbers, or meaning. If an operation cannot be described as one of the
  enumerated edit kinds, it does not belong in this phase.
- Edits are language-aware. German capitalizes nouns; Russian and Ukrainian do
  not. A rule that is correct in one language and wrong in another must be
  keyed by language, not applied globally.

### Edit map and span mapping

- The edit map must translate a range in the raw text into a range in the
  cleaned text, and back.
- Round-tripping is a tested invariant, not an assumption.
- Character offsets follow the Phase 2 convention: `Character` counts, correct
  for umlauts and Cyrillic.

### Risk signals

Each signal is a separate, independently testable unit producing spans with a
reason and a weight:

| Signal | Basis | Notes |
| --- | --- | --- |
| Numbers, dates, currency | Rules | `CriticalTokens` from the benchmark is the starting point; promote it out of `Benchmark/` into the app. |
| Named entities | Rules, per language | The "capitalized mid-sentence" heuristic is invalid in German. Needs a per-language approach or it will fire on every noun. |
| Glossary matches | User dictionary | Scoped by language, per `docs/PRODUCT_SCOPE.md`. A near-miss on a glossary term is a strong signal. |
| Cleanup edits | Edit map | Anything cleanup touched is by definition something the app changed and the user did not say. |
| Language switching | Profile + detection | For mixed profiles, a token in the other language of the pair. |
| Model confidence | Engine | Added last, weight starts at zero, enabled by measurement. |

### False warnings are a budget, not a side effect

`docs/ARCHITECTURE.md` lists false-warning density among the non-negotiable
metrics. A risk engine that marks everything is worse than none: it trains the
user to dismiss the review step, and then the one real error goes through.

- The review decision must have an explicit, testable policy — not an accumulated
  set of conditions.
- Warning density is measured, reported per language, and treated as a
  regression when it rises.

### ReviewCoordinator

- Decides between "done" and "show review", from the risk spans and the policy.
- Review always completes before anything leaves the app.
- The decision is a pure function of its inputs and is unit-tested as one.

### Review strip

Shown only when the risk policy says so. It is the single place where
verification lives.

- Shows the cleaned text with risky spans marked, each with its reason.
- Toggles to the raw transcript.
- Plays the audio fragment for a **flagged span**, from memory, using the token
  timings Phase 2 already produces.
- Audio is discarded when the review is dismissed, when the utterance is
  accepted, or — when no review is shown — as soon as that decision is made.

### Glossary

- User dictionaries scoped by language.
- Editable in Settings.
- Persistence appears here for the first time. It stores user vocabulary only —
  never transcripts, never audio.

## Measurement

Phase 3 extends the Phase 2 harness rather than inventing a second one:

- **Recall of real critical errors** — of the errors the corpus proves are there,
  how many did the engine mark?
- **False-warning density** — marks per hundred words on correct text.
- **Semantic preservation after cleanup** — cleanup must never change meaning;
  this is measured, not asserted.
- All three reported per language profile.

A risk engine without these numbers is not finished, for the same reason an
engine choice without a benchmark was not a choice.

## Acceptance criteria

- Builds and tests under Swift 6 complete concurrency, without warnings.
- Cleanup never alters wording, numbers, or meaning, and every edit is in the map.
- Raw transcript is recoverable at every point in the flow.
- Risky spans land on the correct characters in the cleaned text, verified on
  German umlauts and Cyrillic.
- Every risk signal is unit-tested in isolation, without a model.
- The review decision is deterministic and tested.
- Audio replay works from memory and leaves nothing on disk; the Phase 1
  no-disk-writes test still passes.
- A test asserts that audio is released once the review decision is "no review
  needed", so the recording's lifetime is bounded by the decision.
- Glossary persists across launches; nothing else does.
- Recall, false-warning density, and semantic preservation are measured and
  recorded per language.
- No text is inserted into another application. No analytics, licensing, or
  Stripe code.

## Completion report

- Files and architecture introduced.
- Measured recall, false-warning density, and semantic preservation per language.
- Whether model confidence was enabled, and on what evidence.
- Commands run and their results.
- Manual checks performed, per language.
- Any acceptance criterion that remains unverified.
