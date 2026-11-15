# Punctuation and structure benchmark

Status: **harness and synthetic corpus in place; live corpus not yet recorded.**

## Why this exists

Users report that questions come out as statements and that the text has no
paragraphs, where Wispr Flow gets both right. Until now nothing measured it:
the Phase 2 harness strips punctuation before scoring WER, and the Phase 9.1
structural policies stay disabled for lack of a corpus. This benchmark puts a
number on every candidate fix before one ships: a different Whisper model, a
decoder prompt, Parakeet, a punctuation model, or a local language model.

Two facts from the code shape it:

- Every punctuation mark the user sees comes from Whisper. Cleanup does not
  infer punctuation, with one exception.
- That exception: when Whisper ends an utterance on a letter, Conservative
  cleanup appends a period (`ConservativeCleanupService.terminalPunctuation`).
  A question Whisper left open is therefore inserted as a statement.

So every sample is scored twice: **engine** (Whisper's text) and **inserted**
(after Conservative cleanup, the fresh-install default). The difference between
the two rows is what our own rules add.

## Corpus

`Tools/punctuation_corpus_scripts.json` holds 36 scripts per language for
Russian, Ukrainian, German and English, in seven kinds:

| Kind | Per language | What it tests |
| --- | ---: | --- |
| `yes-no` | 8 | Yes/no questions. In Russian and Ukrainian they carry no question word, so only intonation marks them; in German and English word order does. |
| `wh` | 6 | Questions with a question word. |
| `statement` | 6 | Plain statements and requests. |
| `indirect` | 3 | Statements containing a question word ("I don't know when…"), which must not get `?`. |
| `mixed` | 7 | Two or three sentences mixing questions and statements. |
| `paragraphs` | 3 | Two paragraphs separated by a pause. |
| `list-correction` | 3 | Enumerations and a spoken self-correction, kept verbatim. |

The same scripts feed two corpora, so they compare item by item:

- **Synthetic**: `python3 Tools/make_punctuation_corpus.py [dir]` speaks them
  with the macOS voices (Milena, Lesya, Anna, Samantha) into
  `Benchmark/punctuation-tts/`. A blank line becomes a 1.2 s pause. TTS raises
  pitch at a question mark, but clean, evenly paced synthetic speech is the
  least realistic exactly where it matters most, in intonation-only questions.
  It is a smoke test and a regression guard, not evidence for a decision.
- **Live**: `swift Tools/record_punctuation_corpus.swift ru [dir]` shows each
  script, records it from the default input, and writes
  `Benchmark/punctuation-live/`. It resumes where it stopped; `l` plays a take
  back, `r` redoes it. One language takes about fifteen minutes. Speak as you
  dictate and do not say the punctuation. The recordings never leave the Mac
  and `Benchmark/` is git-ignored.

## Metrics

Words are aligned the way WER aligns them (`TranscriptionScorer.align`, same
normalizer), and the boundary after every reference word is compared with the
boundary after its aligned hypothesis word. A word the engine dropped counts as
a boundary with no mark; an inserted word as a boundary the reference did not
have. Marks are five classes: none, comma (also `;` and `:`), period (also
`…`), exclamation, question. A mark between two digits is part of a number.

| Column | Meaning |
| --- | --- |
| `?` recall | Reference question marks reproduced as `?` at the same word. |
| `?` precision | Hypothesis question marks that the reference has there. |
| `?→.` | Questions written as statements, over all reference questions. |
| `.` F1, `,` F1 | The same for periods and commas. |
| Sentence F1 | A sentence ended where the reference ends one, whichever mark ended it. |
| ¶ recall / precision | Line breaks at aligned boundaries. |
| Open end | Share of samples Whisper ended without any mark. |
| RTF | Inference time over audio time. |

The report also breaks question recall down by kind and lists every question
mistake with reference, engine and inserted text side by side.

## Running

```sh
TEST_RUNNER_BENCHMARK_ENGINE=whisperkit \
TEST_RUNNER_BENCHMARK_CORPUS="$PWD/Benchmark/punctuation-tts" \
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:LocalDictationTests/PunctuationBenchmarkTests/testRunAgainstThePunctuationCorpusIfPresent
```

- `TEST_RUNNER_BENCHMARK_MODEL=<variant>` runs another WhisperKit variant from
  `argmaxinc/whisperkit-coreml`, downloading it into the app's model folder on
  first use. `openai_whisper-large-v3_turbo` is full large-v3 (32 decoder
  layers, 3.2 GB) against the shipped `openai_whisper-large-v3-v20240930_turbo`
  (4 decoder layers, 1.6 GB).
- `TEST_RUNNER_BENCHMARK_PROMPT=style` conditions the decoder on
  `PunctuationBenchmark.stylePrompts`: per language, a statement, a yes/no
  question without a question word, and a comma, sharing no sentence with the
  scripts. The shipped app passes no prompt.

The report is written next to the corpus as `report-<variant>[-prompt].md`.
A first run of a variant in a new DerivedData may spend many minutes in
`ANECompilerService` before the first sample.

## Results

### Synthetic corpus, 2026-11-15

Apple M1, 16 GB, macOS 26.6.2. 144 samples (36 per language), single-language
profiles, so the language is pinned and only punctuation varies. Greedy
decoding is deterministic: a second run of the same variant reproduced every
number.

**Shipped model, no prompt** (`openai_whisper-large-v3-v20240930_turbo`):

| Language | WER | `?` recall | `?` precision | `?→.` | `.` F1 | `,` F1 | Sentence F1 | ¶ recall | Open end | RTF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| English | 1% | 100% | 100% | 0/22 | 93% | 78% | 96% | 0% | 0% | 0.22 |
| German | 1% | 100% | 100% | 0/22 | 97% | 94% | 98% | 0% | 0% | 0.19 |
| Russian | 1% | 45% | 91% | 8/22 | 87% | 87% | 95% | 0% | 0% | 0.22 |
| Ukrainian | 3% | 27% | 86% | 16/22 | 79% | 95% | 99% | 0% | 0% | 0.21 |

Question recall by kind:

| Kind | English | German | Russian | Ukrainian |
| --- | ---: | ---: | ---: | ---: |
| yes-no | 8/8 | 8/8 | 4/8 | 0/8 |
| wh | 6/6 | 6/6 | 2/6 | 4/6 |
| mixed | 7/7 | 7/7 | 3/7 | 2/7 |
| paragraphs | 1/1 | 1/1 | 1/1 | 0/1 |

What this says, within the limits of synthetic speech:

- The question problem is Russian and Ukrainian. English and German got every
  question right, as they would from word order alone.
- In Russian and Ukrainian Whisper misses questions even with a question word:
  `когда ты будешь дома.`, `де лежать документи щодо договору оренди.`, often
  lower-cased as if continuing a sentence. A text-only punctuation model could
  recover those; intonation-only yes/no questions need the audio.
- In a mixed passage Whisper tends to swallow the question into the next
  sentence with a comma: `Цена нормальная, мне кажется, можно попросить скидку.`
- Both Russian and Ukrainian wrote the indirect `Скажи мне, где ты оставил
  ключи?` as a question, so a fix must not reward "question word means `?`".
- Whisper never wrote a line break: paragraph recall is 0% in every language,
  so paragraphs need a structural pass whatever the engine.
- No sample ended open, so on clean single utterances our appended period
  never fired and every mistake above is Whisper's. The rule matters where
  speech is cut mid-sentence: in the local meeting notes 19% of Cyrillic and
  30% of Latin windows end without a mark.

**Full large-v3** (`openai_whisper-large-v3_turbo`, 32 decoder layers, 3.2 GB):

| Language | WER | `?` recall | `?` precision | `?→.` | yes-no | wh | mixed | RTF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| English | 1% | 100% | 100% | 0/22 | 8/8 | 6/6 | 7/7 | 0.62 |
| German | 1% | 95% | 100% | 0/22 | 8/8 | 6/6 | 6/7 | 0.57 |
| Russian | 1% | 73% | 94% | 5/22 | 5/8 | 4/6 | 6/7 | 0.66 |
| Ukrainian | 5% | 32% | 78% | 14/22 | 0/8 | 5/6 | 2/7 | 0.69 |

The deeper decoder lifts Russian from 45% to 73% and barely moves Ukrainian
(27% to 32%, yes/no still 0/8), at three times the inference time on an M1
(RTF 0.21 to 0.64: a ten-second dictation waits about 6.4 s instead of 2.1 s).
It still writes `когда ты будешь дома.` and the indirect question with `?`,
still has no paragraphs, and German lost one question into a comma splice.
Not a decision on its own: the Ukrainian TTS voice may simply not raise its
pitch, which only the live corpus can settle.

**Shipped model + style prompt**: rejected. 38 of 144 utterances came back
empty, WER rose from 2% to 29% and question recall fell from 68% to 40%. This
matches WhisperKit's own warning that `<|startofprev|>` biases the decoder
toward ending a segment early. A static prompt is not a punctuation lever on
this stack.

Reports with every question mistake: `Benchmark/punctuation-tts/report-*.md`.
