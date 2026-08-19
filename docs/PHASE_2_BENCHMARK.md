# Phase 2 — transcription benchmark

Status: **harness implemented and unit-tested; no corpus run has been performed yet.**

This file holds the methodology and, once a corpus is installed, the results.
It contains no measured numbers today, because none have been measured. The
engine decision is not final until the table below is filled in from a real run.

## Candidates

| Engine | Adapter | License | Model | Deployment target | Per-token confidence |
| --- | --- | --- | --- | --- | --- |
| Apple on-device `SFSpeechRecognizer` | `AppleSpeechTranscriptionService` | System framework | Bundled with macOS | macOS 14.4 ✓ | Reported per segment, frequently `0` on device |
| Whisper via WhisperKit 1.1.0 | `WhisperKitTranscriptionService` | MIT | `openai_whisper-large-v3-v20240930_turbo`, ~600 MB, downloaded | macOS 13+ ✓ | `WordTiming.probability` per word |

### Not admitted

- **Apple `SpeechAnalyzer` / `SpeechTranscriber`.** The native answer, and the
  one to revisit later, but it requires macOS 26. Adopting it today would drop
  every user on macOS 14 and 15. Recorded as a deliberate deployment-target
  trade-off rather than a silent exclusion.
- **distil-whisper variants.** Much faster and much weaker outside English.
  `WhisperKit.recommendedModels()` can return one, which is exactly why the
  adapter pins a multilingual variant instead of trusting the recommendation.

### Dependency rationale

`AGENTS.md` requires that a third-party dependency be justified before it is
added. The justification is narrow and specific:

No system framework at the macOS 14.4 deployment target returns per-word
confidence. `SFSpeechRecognizer` binds one recognizer to one locale — so it
cannot serve a mixed profile at all — and its `SFTranscriptionSegment.confidence`
is routinely `0` for on-device recognition. Phase 3's entire product promise is
showing the user which fragments are worth checking, and that cannot be built on
an engine that does not say when it is unsure.

WhisperKit is MIT-licensed, runs fully on-device via Core ML, covers all four
MVP languages, and returns a real per-word probability. The adapter treats a
reported confidence of `0` from Apple's engine as *absent* rather than as
certainty, so the benchmark cannot mistake a missing signal for a calibrated one.

## Metrics

Accuracy, per language and pooled over tokens rather than averaged over samples:

- **WER** and **CER** — the standard baseline.
- **Numeric error rate** — errors restricted to digits, currency, and spelled-out
  number words in all four languages. Reported separately because a transcript
  can be 97% correct and still have the amount wrong, and that single error is
  the one the product exists to catch.

Product-critical:

- **Confidence separation** — mean confidence on correct tokens minus mean
  confidence on wrong ones. Around zero means the engine is just as sure when it
  is wrong, and Phase 3 has nothing to point at.
- **Risk recall** at a confidence threshold — the share of genuinely wrong tokens
  that threshold would have flagged.
- **False-warning rate** — the share of correct tokens it would have flagged anyway.

Performance:

- **Real-time factor** — inference time over audio length, pooled across samples.
- Model size on disk and peak memory, recorded per run.

**Confidence separation is the deciding metric.** An engine that wins on WER but
shows no separation does not qualify, because Phase 3 cannot be built on it.

## Named entities are deliberately not scored yet

The usual heuristic — a capitalized word mid-sentence is an entity — is
meaningless in German, where every noun is capitalized. Entity scoring needs a
tagged corpus. It is left out rather than shipped as a heuristic that would
silently report nonsense for the primary launch market.

## Running the benchmark

The corpus lives outside the repository. `/Benchmark/` is git-ignored, so
licensed speech data is never committed and never leaves the machine.

1. Create `Benchmark/` in the repository root.
2. Add audio files. Any format Core Audio reads is fine — the loader normalizes
   to mono Float32 at 16 kHz through the same converter the live capture path
   uses, so an engine sees benchmark audio exactly as it sees dictation.
3. Add `Benchmark/corpus.json`:

```json
{
  "name": "phase-2-smoke",
  "samples": [
    {
      "audio": "de/0001.wav",
      "reference": "Bitte überweise 1450 Euro bis Freitag.",
      "language": "de",
      "profile": "de+en"
    },
    {
      "audio": "uk/0001.wav",
      "reference": "Рахунок на дві тисячі гривень.",
      "language": "uk"
    }
  ]
}
```

`profile` is optional and defaults to the sample's own single-language profile.

4. Run the harness against a chosen engine:

```sh
TEST_RUNNER_BENCHMARK_ENGINE=whisperkit xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -only-testing:LocalDictationTests/BenchmarkRunnerTests/testRunAgainstTheInstalledCorpusIfPresent
```

`BenchmarkRunnerTests.testRunAgainstTheInstalledCorpusIfPresent` skips when no
manifest is present. `BENCHMARK_ENGINE` accepts `whisperkit` or `apple`; unset,
it runs a fake engine that checks the harness in a second and measures nothing.

The `TEST_RUNNER_` prefix is mandatory — `xcodebuild` does not forward the shell
environment to the test process, and strips that prefix to inject the variable.
Without it the run silently uses the fake engine.

The rendered table is written to `Benchmark/report-<engine>.md` for pasting into
the results section below.

**Check free disk space first.** The Whisper weights are roughly 600 MB
compressed and about 1 GB unpacked, on top of 1.5–2 GB of DerivedData. On a full
disk the download fails and WhisperKit reports it as
`Model not found. Please check the model or repo name and try again` — the real
cause, `No space left on device`, is only visible in the attached error. Budget
at least 5 GB free before a run:

```sh
df -h /System/Volumes/Data
```

**Avoid running this concurrently with another `xcodebuild` or with Xcode
building the same scheme.** They share DerivedData and can corrupt each other's
result bundle, producing errors that name `mkstemp` and give no hint of the
cause. Isolate it if you want to keep working:

```sh
TEST_RUNNER_BENCHMARK_ENGINE=whisperkit xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/localdictation-benchmark -only-testing:LocalDictationTests/BenchmarkRunnerTests/testRunAgainstTheInstalledCorpusIfPresent
```

### A synthesized smoke corpus is not a benchmark

`python3 Tools/make_smoke_corpus.py` generates TTS audio for all four languages,
which is enough to prove the harness runs end to end — useful when no human
speaker is available for a language. It is not evidence about accuracy:
synthesized speech is unnaturally clean and evenly paced, and number formatting
differences between the reference and the engine's output (`1450` versus
`1.450`) will dominate the numeric error rate for reasons that have nothing to
do with recognition quality.

### Corpus requirements

- Every one of DE, EN, RU, and UK, plus the priority mixed profiles.
- Utterances that look like the product's real input: task notes, ticket
  comments, email fragments, AI prompts — not read literary prose.
- Deliberate coverage of amounts, dates, currency, names, and negation, since
  those drive the numeric error rate and the calibration numbers.
- Enough samples per language that the pooled rates are not dominated by one
  recording. Treat fewer than roughly 50 utterances per language as indicative
  only, and say so in the results.

## Observations so far

Not benchmark results — these came out of getting the harness to run, and are
recorded because they bear directly on the engine decision.

- **Apple has on-device models for only one of the four MVP languages here.**
  Probing `SFSpeechRecognizer` on a macOS 26.2 machine:

  | Locale | `supportsOnDeviceRecognition` | `isAvailable` |
  | --- | --- | --- |
  | `en-US` | true | true |
  | `de-DE` | false | true |
  | `ru-RU` | false | true |
  | `uk-UA` | false | true |

  The system log explains it: `No Assistant asset for language de-DE`. Adding the
  language under General → Language & Region does **not** fetch the offline asset;
  it is downloaded by adding the language under Keyboard → Dictation.

  `isAvailable == true` alongside `supportsOnDeviceRecognition == false` is a trap
  worth naming: the recognizer works, but only by sending audio to Apple's
  servers. For this product that is not a degraded mode, it is a forbidden one.
  `AppleSpeechTranscriptionService` pins `requiresOnDeviceRecognition = true` and
  fails loudly instead, which is why the failure surfaced at all.

  The consequence for the engine decision is direct: on a stock machine Apple's
  engine cannot serve German, Russian, or Ukrainian locally, and the launch
  market is Germany. Whether an asset is present depends on a Dictation setting
  the user has probably never opened, so any product built on `SFSpeechRecognizer`
  would have to detect this per language and walk the user through fixing it.
- Because of this, engine preparation happens **per language profile inside the
  benchmark run**, and a language an engine cannot serve is recorded as a failure
  row rather than aborting the whole run. An engine that handles three of four
  languages must still be measurable on those three.

## Results

### WhisperKit, TTS smoke corpus, 2026-08-19

`openai_whisper-large-v3-v20240930_turbo` · WhisperKit 1.1.0 · macOS 26.2 ·
Apple M1, 8 cores · corpus `tts-smoke`, 6 synthesized utterances per language.

| Language | Samples | WER | CER | Numeric ER | RTF | Confidence separation | Risk recall @ 0.5 | False warnings |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| German | 0 | — | — | — | — | — | — | — |
| English | 6 | 21.4% | 17.6% | 55.6% | 4.17 | 0.203 | 33.3% | 0.0% |
| Russian | 6 | 15.2% | 19.4% | 0.0% | 3.90 | −0.008 | 0.0% | 0.0% |
| Ukrainian | 6 | 21.2% | 18.8% | 0.0% | 3.23 | 0.121 | 20.0% | 0.0% |
| **Overall** | 18 | 19.4% | 18.6% | 26.3% | 3.73 | 0.133 | 21.4% | 0.0% |

**This is not evidence about quality.** Six synthesized utterances per language
is far too few for any of these figures to be stable, and the audio is not what
the product will actually receive. What the run does establish is that the
WhisperKit adapter works end to end on real inference in three languages, and
that the harness reports what it measures.

Read with these caveats:

- **German scored zero samples for a transient reason, not a real one.** German
  is first in the corpus, so its profile triggered the model download while the
  machine was still out of disk space. The download completed during the English
  profile and the remaining languages ran normally. German needs a re-run, and
  nothing here says anything about Whisper's German.
- **RTF near 3.7 is not the product's latency.** Whisper pads every input to a
  30-second window, so on 2–4 second utterances the fixed cost dominates and the
  ratio is meaningless. What matters is absolute end-of-speech to text, measured
  on utterances of realistic length. That has not been measured.
- **WER around 19% is not yet attributable.** The reference says `1450`; the
  engine may write `1,450`, which normalization splits into two tokens and scores
  as errors. The 55.6% English numeric error rate next to 0.0% for Russian and
  Ukrainian is the signature of a formatting mismatch, not of the engine being
  four times worse at English numbers. **The harness cannot currently tell these
  apart, because the report does not record the hypothesis text.** That is the
  first thing to fix.

### The finding that actually matters

**Confidence separation is weak, and for Russian it is negative.** Overall 0.133;
Russian −0.008, meaning Whisper was very slightly *more* confident when it was
wrong. Risk recall at a 0.5 threshold is 21.4% overall and 0% for Russian, while
false warnings are 0% everywhere — the probabilities sit high and bunched, for
correct and incorrect tokens alike.

If this holds on real speech and a real corpus, it undercuts the assumption
Phase 3 rests on. Raw token probability alone would not be enough to decide what
to show the user, and the risk engine would have to lean much harder on the other
signals `docs/ARCHITECTURE.md` lists: number and entity rules, language
switching, glossary matches, and cleanup edits.

It does not change the engine decision — WhisperKit remains the only candidate
with any usable confidence signal, and Apple's engine cannot serve three of the
four languages offline at all. But it does mean the Phase 3 design should be
validated against measured calibration before it is built, not after.

Record with every run: corpus name and size, model variant, WhisperKit version,
macOS version, and machine.

## Decision

**WhisperKit. Apple's on-device engine is dropped as a candidate.**

Decided 2026-08-19, on admission criteria rather than on accuracy — the accuracy
comparison never became necessary, because `SFSpeechRecognizer` failed the
entry requirements outright:

1. **It cannot serve three of the four MVP languages offline.** On a stock
   macOS 26.2 machine only `en-US` has an on-device asset. German, Russian, and
   Ukrainian report `supportsOnDeviceRecognition == false`, and the launch market
   is Germany. Whether an asset exists depends on a Dictation setting most users
   have never opened, and it is not something the product can fix for them.
2. **What it offers instead is forbidden here.** Those same locales report
   `isAvailable == true`, because recognition works by sending audio to Apple's
   servers. That is not a fallback this product is allowed to take.
3. **One recognizer binds to one locale**, so the mixed profiles from
   `docs/PRODUCT_SCOPE.md` cannot be served at all.
4. **Its confidence signal is frequently `0` on device**, which Phase 3 cannot
   build on.

`AppleSpeechTranscriptionService` stays in the tree. It is the evidence behind
the dependency this project took on, per `AGENTS.md`, and it keeps a second
implementation of `TranscriptionService` honest — proving the protocol is not
quietly shaped around Whisper. It is no longer a candidate, and no further
benchmarking of it is planned.

Revisit if `SpeechAnalyzer` becomes viable — that is, once macOS 26 is an
acceptable minimum and its language coverage and confidence signal are checked
against the same criteria.
