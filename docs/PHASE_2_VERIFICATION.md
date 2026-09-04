# Phase 2 — verification checklist

What a person at the keyboard has to check, and what the machine already checks
by itself. Tick items here and record the outcome; anything left unticked stays
an unverified acceptance criterion in the phase report.

## 0. Language coverage of the human checks

The maintainer speaks Russian, English, and Ukrainian. **German live dictation
cannot be self-verified** and is the largest open gap, because Germany is the
launch market. German is currently covered only by synthesized audio, which
proves the pipeline runs but says nothing about real accuracy.

Close that gap before Phase 2 is called done — a German-speaking tester, or
recordings from one.

## 1. Automated (no microphone, no model)

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
```

- [ ] `** TEST SUCCEEDED **`, 128 tests, no warnings.
- [ ] Release also compiles, which proves the Debug-only benchmark code is
      genuinely excluded from a shipping build:

```sh
xcodebuild build -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -configuration Release
```

## 2. Harness smoke test (no recording needed)

Generates synthesized audio for all four languages and runs the benchmark over it.

```sh
python3 Tools/make_smoke_corpus.py
```

```sh
TEST_RUNNER_BENCHMARK_ENGINE=whisperkit xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -only-testing:LocalDictationTests/BenchmarkRunnerTests/testRunAgainstTheInstalledCorpusIfPresent
```

The `TEST_RUNNER_` prefix is required and is not decoration: `xcodebuild` does
not pass the shell environment to the test process, it strips that prefix and
injects the rest. Without it the variable never arrives, the test quietly falls
back to the fake engine, and passes in a fraction of a second while measuring
nothing. If the run finishes suspiciously fast, that is what happened.

The first run downloads roughly 600 MB of Whisper weights. The rendered table
lands in `Benchmark/report-whisperkit.md`.

- [ ] All 24 samples are scored; the failure list is empty.
- [ ] Every language produces a row.
- [ ] Confidence separation is a number, not `n/a` — this is the metric that
      decides whether Phase 3 is buildable at all.

Before scoring the Apple candidate, check which languages it can serve offline
on this machine:

```sh
swift Tools/probe_speech_models.swift
```

A language reported as `available` but not `on-device` works only by sending
audio to Apple's servers, which this product never does — count it as
unsupported. Offline assets are fetched via System Settings → Keyboard →
Dictation → Languages, not via Language & Region.

Swap `whisperkit` for `apple` to score the other candidate. That one asks for
speech-recognition permission the first time, so it needs someone present, and
it will report a failure row for any language whose on-device model macOS has
not installed — German is absent by default on an English-language system.

Check free space before starting — `df -h /System/Volumes/Data`. The run needs
about 5 GB. On a full disk WhisperKit reports `Model not found`, which points at
the model name and not at the actual cause.

Avoid running this while Xcode or another `xcodebuild` is building the same
scheme; they share DerivedData and can corrupt each other's result bundle. Add
`-derivedDataPath /tmp/localdictation-benchmark` to isolate it.

**These numbers are not a quality benchmark.** Synthesized speech is unnaturally
clean and evenly paced. Expect the numeric error rate to look bad for a boring
reason: the reference says `1450` and Whisper may write `1.450` or spell it out.
That mismatch is formatting, not misrecognition — and noticing the difference is
itself part of what Phase 3 has to handle.

## 3. Live dictation

Build and run from Xcode, or launch the built app. It has no Dock icon; look in
the menu bar.

1. [ ] Nothing prompts for microphone or speech access **at launch**. The
       permission dialog appears only after the explicit menu action.
2. [ ] Pick a language profile in the menu.
3. [ ] Press **Prepare speech model…** and wait for `Ready`.
4. [ ] Hold `⌥Space`, speak, release. The status goes
       `Recording → Finishing utterance → Transcribing → Ready`, and the raw
       transcript appears in the panel.

### Sentences to dictate

Each one deliberately carries the categories the product promises to protect:
an amount, a date, a name, and a negation. Read them naturally, at normal pace.

**Russian**

1. Переведи 1450 евро Мюллеру до пятницы.
2. Встреча третьего марта не подтверждена.
3. Счёт всё ещё открыт, сумма 89 евро.
4. Мы не отгрузим раньше пятнадцатого апреля.
5. Остаток две тысячи пятьсот евро.

**English**

1. Please transfer 1450 euro to Miller by Friday.
2. The meeting on March third was not confirmed.
3. The invoice is still open, amount 89 euro.
4. We will not ship before April fifteenth.
5. Balance two thousand five hundred euro.

**Ukrainian**

1. Переказати 1450 євро Мюллеру до п'ятниці.
2. Зустріч третього березня не підтверджена.
3. Рахунок усе ще відкритий, сума 89 євро.
4. Ми не відвантажимо раніше п'ятнадцятого квітня.
5. Залишок дві тисячі п'ятсот євро.

For each language, record:

- [ ] Did any **number** come out wrong?
- [ ] Did any **negation** disappear? A dropped "не" flips the meaning and is
      the worst failure this product can have.
- [ ] Did the **name** survive?
- [ ] Roughly how long from releasing the key to seeing text?

### Mixed profiles

- [ ] Select `Russian + Ukrainian` or `Ukrainian + English` and dictate a
      sentence that genuinely switches language mid-way. Whisper is asked to
      detect the language itself for mixed profiles, so this is the path that
      has never been exercised.

## 4. Phase 2 behaviour that is easy to get wrong

- [ ] **Supersede.** Dictate something long. While the status still reads
      `Transcribing`, press `⌥Space` again and dictate something short. The
      first transcript must never appear — only the second.
- [ ] **Copy.** The copy button puts the text on the clipboard, and nothing
      else does. No text is typed into any other application in this phase.
- [ ] **Switching profile** while idle does not clear or corrupt the last
      transcript display.
- [ ] **Failure recovery.** Deny speech access, dictate, confirm the panel shows
      an actionable message and **Try again** returns the app to `Ready`.
- [ ] Open the menu while a transcription is running — the status must stay
      `Transcribing`, not snap back to `Ready`.

## 5. Diagnostics

In Settings → developer diagnostics, after an utterance:

- [ ] Engine, profile, token count, real-time factor, and mean/minimum
      confidence are populated.
- [ ] No transcript text appears in any log line. Confirm with:

```sh
log show --predicate 'subsystem == "com.witnessmac.Witness"' --last 10m --info
```

Device names, formats, durations, and counters are expected there. Recognized
words are not.

## 6. Still open from Phase 1

Never verified, and Phase 2 does not change them:

- [ ] Ten minutes of repeated short recordings without memory growth.
- [ ] Unplugging or switching the input device mid-recording.
- [ ] Revoking microphone access in System Settings while the app runs, then
      the denied → Privacy Settings → re-check loop.
