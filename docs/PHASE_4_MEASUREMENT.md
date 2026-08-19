# Phase 4 — what the review costs on ordinary text

`docs/PHASE_4.md` made one Phase 3 number a requirement rather than an
observation: false-warning density measured on **ordinary prose**, with the flag
threshold revisited against it before the phase can be called complete.

The reason is that the cost changed. In Phase 3 a needless mark added a strip to
a panel the user had opened anyway. In Phase 4 it interrupts the path that would
otherwise show no window at all — the one the phase exists to create.

## How it is measured

The same harness as Phase 3, `RiskBenchmark.runOnReferences`, over a different
corpus. No speech engine and no audio: the hypothesis *is* the reference, so
every mark is by definition a mark on correct text.

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -only-testing:LocalDictationTests/ProseWarningDensityTests
```

The corpus is committed, in `LocalDictationTests/Support/ProseCorpus.swift`: 56
sentences, fourteen per language, of the kind actually dictated at work — tasks,
ticket comments, mail, notes. It carries no licensed speech and no audio, which
is why it can live in the repository when the Phase 2 corpus cannot, and why
this measurement runs on every test run instead of only where a corpus happens
to be installed.

Its shape is the point. The Phase 3 smoke corpus was written so that every
sentence carries an amount, a date, a name, and a negation, because that is what
makes it useful for recall — and what makes its density an upper bound rather
than a typical figure. Here, figures appear at roughly the rate they appear in
real writing, and German keeps its capitalized nouns.

## Result

| Language | Samples | Words | Marks | Marks/100 words | Utterances reviewed |
| --- | ---: | ---: | ---: | ---: | ---: |
| de | 14 | 141 | 5 | 3.5 | 21 % |
| en | 14 | 140 | 5 | 3.6 | 21 % |
| ru | 14 | 106 | 6 | 5.7 | 21 % |
| uk | 14 | 101 | 6 | 5.9 | 21 % |
| **all** | **56** | **488** | **22** | **4.5** | **21 %** |

By signal, over the whole corpus: 18 number, 4 date. Nothing else fires at all —
no entity, no glossary, no cleanup edit, no language switch.

Semantic preservation is 100 %, as it must be.

**The Phase 3 figure of 25.4 marks per hundred words was corpus-shaped.** On
ordinary prose the same engine marks 4.5, and roughly one utterance in five
carries a mark heavy enough to interrupt.

## What the measurement found, beyond the number

An ordinal was being read as a date wherever it appeared. "den zweiten Absatz"
and "the second paragraph" were marked, with **date** as the reason the user
would read.

That is worse than a needless mark. A mark whose reason is visibly nonsense is
exactly what teaches someone to dismiss the review without looking, and then the
one real error goes through with it.

So it was fixed rather than tuned away. A bare ordinal is a date only when
something says it is: a month word within two positions, or a preposition that
introduces a date — "am fünfzehnten", "до пятнадцатого". Months and weekdays
still need nothing; they are dates on their own. The rule lives in
`CriticalTokens`, so the definition that marks a transcript and the definition
that scores a corpus remain the single definition Phase 3 promoted them into
being.

The fix moved density from 4.9 to 4.5 and the review rate from 25 % to 21 %.

## What was left alone, and why

**The flag threshold stays at 0.5.**

Every mark remaining on ordinary prose comes from the number and date signals —
the two the product's promise rests on. Their weight is 0.8, so any threshold
that suppressed them would have to be above 0.8, which is not tuning the review
step but switching it off. There is nothing left in this corpus to trade away.

## Known limitations of a word-list rule

Recorded rather than hidden, because they are the next thing to look at if the
number rises:

- **"одна" / "одне" is marked.** In "причина у них одна" it means "the same",
  not "one", and a word list cannot tell those apart. This accounts for the gap
  between the Russian and Ukrainian rows and the German and English ones.
- **Small spelled-out counts are marked** — "drei Tickets", "three tickets". By
  the Phase 3 reasoning about memory this is the weakest case for a mark: a
  count in a sentence is closer to meaning than to digits, and meaning is what
  the speaker can still check by reading. It is left in place because the
  alternative is a magnitude rule with no evidence behind it yet.
- **The corpus is written, not spoken.** It measures the rules, not the way
  people actually talk to a microphone. Real dictation carries fillers, restarts,
  and the engine's own errors, and only a real corpus will show what those do to
  this number.
