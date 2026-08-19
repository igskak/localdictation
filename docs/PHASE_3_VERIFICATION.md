# Phase 3 — verification checklist

What a person at the keyboard has to check, and what the machine already checks
by itself. Tick items here and record the outcome; anything left unticked stays
an unverified acceptance criterion in the phase report.

## 0. What is still unverified from Phase 2

Unchanged and still open:

- **German live dictation cannot be self-verified.** The maintainer speaks
  Russian, English, and Ukrainian. German is the launch market and is covered
  only by synthesized audio. Phase 3 makes this worse, not better: the German
  entity rules — title markers and acronyms — have never been exercised on real
  German speech.
- Ten minutes of repeated short recordings without memory growth. Phase 3 adds
  a retained audio buffer, so this now has a specific thing to check.
- Unplugging or switching the input device mid-recording.

## 1. Automated (no microphone, no model)

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
```

- [ ] `** TEST SUCCEEDED **`, 259 tests, 2 skipped (corpus-gated), no warnings.
- [ ] Release also compiles, which proves the Debug-only benchmark and risk
      measurement code is genuinely excluded from a shipping build:

```sh
xcodebuild build -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -configuration Release
```

## 2. Measurement (no microphone, no model)

The model-free half of the Phase 3 numbers — false-warning density and semantic
preservation — needs only a corpus manifest:

```sh
python3 Tools/make_smoke_corpus.py
```

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -only-testing:LocalDictationTests/RiskBenchmarkTests/testRunAgainstTheInstalledCorpusIfPresent
```

- [ ] Every language produces a row.
- [ ] Semantic preservation is 100% everywhere. Anything below that is cleanup
      changing what the user said, and is a defect, not a tuning question.
- [ ] The report lands in `Benchmark/risk-reference.md`.

The recall half needs the engine and the audio. See `docs/PHASE_3_MEASUREMENT.md`.

## 3. Live dictation

Build and run from Xcode. No Dock icon; look in the menu bar.

### The quiet path — the one that must not annoy

1. [ ] Dictate a sentence with **no** amount, date, or name: "the meeting was
       moved to the usual room". The text appears with **no review strip**, and
       the status returns to `Ready` immediately.
2. [ ] Settings → Diagnostics → **Audio lifetime → Retained frames** reads `0`
       right after that sentence. This is the acceptance criterion about the
       recording's lifetime, visible from the UI.

### The review path

3. [ ] Dictate "please transfer 1450 euro to Miller by Friday". The status
       reads **Worth a look** and the strip appears with the amount, the
       currency, and the name marked.
4. [ ] Each mark carries a reason you can read, not just a colour.
5. [ ] Press the play button on the amount. You hear **that fragment**, not the
       whole utterance.
6. [ ] **Show raw transcript** switches to exactly what the engine produced,
       and back.
7. [ ] **Copy** copies whichever of the two you are looking at.
8. [ ] **Done** dismisses the strip, and Retained frames goes to `0`.

### Per language

Use the Phase 2 sentences in `docs/PHASE_2_VERIFICATION.md` — they were written
to carry an amount, a date, a name, and a negation each.

For each of German, English, Russian, and Ukrainian, record:

- [ ] Did the **amount** get marked?
- [ ] Did the **date** get marked?
- [ ] Did the **name** get marked? (In German this only works via a title —
      "Frau Schneider" — or a dictionary entry. That is by design; see below.)
- [ ] Did the review appear when it should, and stay away when it should not?
- [ ] Did cleanup change any **word**? It must not. Punctuation, capitalization
      of the first letter, spacing, and a removed "ähm" are the only permitted
      changes.

### German entity detection is deliberately narrow

German capitalizes every noun, so "capitalized mid-sentence" marks most of the
sentence and means nothing. The heuristic is **switched off** for German, and
German names are found only by a title marker ("Herr", "Frau", "Dr.") or by the
dictionary.

- [ ] Dictate "Die Rechnung für die Prüfung der Verträge ist offen" — **no**
      name marks. If nouns get marked here, the language keying broke.
- [ ] Dictate "Frau Schneider hat den Vertrag abgelehnt" — "Schneider" is
      marked.

## 4. Dictionary

- [ ] Settings → Dictionary → add "Müller" under DE.
- [ ] Dictate a sentence where it is likely to be misheard. If it comes out as
      "Miller" it is marked as close to "Müller"; if it comes out right it is
      **not** marked.
- [ ] Quit and relaunch. The term is still there.
- [ ] Nothing else survives the relaunch: the previous transcript is gone.
- [ ] The file at the path shown in Settings contains terms and languages only.

## 5. Behaviour that is easy to get wrong

- [ ] **Supersede a review.** Leave a review strip open and press `⌥Space`
      again. The strip disappears, the old result is gone, and Retained frames
      is `0` before the new recording finishes.
- [ ] **Menu reopen.** Close and reopen the menu while a review is showing. The
      review is still there and the status has not snapped back to `Ready`.
- [ ] **Failure.** Force a transcription failure. The panel shows an actionable
      message, **Try again** returns to `Ready`, and Retained frames is `0`.
- [ ] **No insertion.** Nothing is typed into any other application at any
      point in this phase.

## 6. Logging

```sh
log show --predicate 'subsystem == "com.localdictation.LocalDictation"' --last 10m --info
```

- [ ] Counts of edits, spans, and flagged spans appear.
- [ ] **No recognized word, no marked fragment, and no dictionary term appears
      in any log line.**
