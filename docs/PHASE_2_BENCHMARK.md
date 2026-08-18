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

**Do not run this concurrently with another `xcodebuild` or with Xcode building
the same scheme.** Two `xcodebuild test` invocations sharing one DerivedData
clobber each other's result bundle, and the run dies with
`mkstemp: No such file or directory` after having done all the work. Isolate it
if you want to keep working:

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

- **Apple's on-device German model is not present by default.** On a macOS 26.2
  machine with an English system language, `prepare(for:)` on the German profile
  fails with *"macOS has no on-device German model"* until the language is added
  under System Settings → General → Language & Region. Germany is the launch
  market, so for `SFSpeechRecognizer` this is not a detail: the product's primary
  language depends on a system setting the user has probably never touched, and
  the app would have to detect and explain that.
- Because of this, engine preparation happens **per language profile inside the
  benchmark run**, and a language an engine cannot serve is recorded as a failure
  row rather than aborting the whole run. An engine that handles three of four
  languages must still be measurable on those three.

## Results

Not yet measured. Fill in per engine once a corpus is installed:

| Language | Samples | WER | CER | Numeric ER | RTF | Confidence separation | Risk recall | False warnings |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |

Record with every run: corpus name and size, model variant, WhisperKit version,
macOS version, and machine.

## Decision

Pending the run above.

WhisperKit is wired as the development default in `DictationCoordinator.makeLive()`
because it is the only admitted candidate that meets the per-token confidence
requirement at all. That is an admission criterion, not a benchmark result, and
it does not settle accuracy, latency, or calibration in any language.
