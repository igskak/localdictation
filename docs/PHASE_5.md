# Phase 5 — verification that does not interrupt

## Objective

Take the last thing standing between the user and their own text away, and make
the marks that remain worth reading.

```text
transcript ready
  -> insert into the captured target, always, without asking anybody
  -> price the marks
       -> nothing above the attention threshold: silence, audio released
       -> something above it: light a triangle, hold the audio for replay
  -> the review opens only if the user asks: from the chip, or from the menu
```

The phase exists because of a report from use, not from a plan. Two sentences
of it are the whole specification:

> It highlights the name of a messenger — logically, because it is risky. And
> the word "проверка", which the recognizer wrote as "ррверка", it did not
> highlight. Highlighting risks happens often enough, and far from always
> relevantly.

Both halves matter, and fixing either alone would leave the complaint standing.
The app was pointing at a word that was correct, saying nothing about a word
that was not, and it was doing both while holding the text hostage to a panel.

## What changed, and why each change was necessary

### One threshold became two

`ReviewPolicy` had a single `flagThreshold` at 0.5 doing two jobs: deciding what
to highlight, and deciding whether to interrupt. The entity signal is a
capitalization heuristic priced at 0.6, so **every correctly recognized product,
company, or person name interrupted on its own.** That is the reported
behaviour, and it was not a bug in the signal — it was the price list.

The two questions are now priced separately:

- `attentionThreshold`, 0.8. The only number that can cost the user anything.
- `displayThreshold`, 0.3. What the review draws once the user has opened it.

Nothing else about the entity heuristic changed. It still marks capitalized
words, it is still wrong about many of them, and that is now affordable: the
mark is an underline inside a page the user opened on purpose.

### A word that is not a word is now a signal

The engine had no way to notice `ррверка`. Its only lexical check was
`GlossaryRiskSignal`, which fires on near-misses against terms the user typed in
themselves — a word resembling nothing in that list passed through untouched.

The obvious fix was measured before it was written, and it does not work. On a
stock Mac the Russian spelling dictionary does not contain `деплой`, `коммит`,
`бэкенд`, `апи`, or `аутентификация`; the English one does not contain
`webhook`. "Mark every word the dictionary does not know" would have marked a
large share of the ordinary working vocabulary of the person this app is for —
the same failure, relocated.

So `MalformedWordSignal` requires two independent failures:

1. **An impossible shape.** A doubled consonant opening a word; a run of more
   than five consonants; no vowel at all. These are facts about the characters.
   `ррверка` and `пперевірка` fail; `деплой`, `Скаковский`, `strengths`, and
   `бодрствовать` pass.
2. **Unknown to the system dictionary.** Which only ever *removes* marks.

The consonant-run rule is switched off for German, exactly as the capitalization
heuristic is in `EntityRiskSignal` and for the same reason: *Angstschweiß* has
eight consonants in a row and is ordinary German. A rule that fires on most of a
language is not a weaker signal, it is a broken one.

Priced at 0.85, above the attention threshold — this is the one thing the user
cannot catch by rereading their own sentence, because a mangled word looks
wrong only if you are looking.

### The dictionary now silences marks as well as earning them

An exact glossary match produced no span, which meant it also suppressed
nothing: adding `Флок` to the dictionary did not stop the app marking it as a
risky name every single time it came out correctly. A term the user typed into
Settings is a word. `EntityRiskSignal` and `MalformedWordSignal` both skip them
now.

### `.reviewing` left the state machine

Reading a report about text that is already in the document is not a phase of
dictation. It was modelled as one, which is why every review blocked the
pipeline it was reporting on. The review is now presentation state
(`isShowingReview`), and `RecordingState` is one case shorter.

### The review lost its decision

It has no Accept and no Discard, because there is nothing left to accept: the
text has been in the user's document since it was recognized. What it has are a
report's actions — show the raw transcript, replay a fragment, take a copy,
close.

The app deliberately does **not** offer to replace the text it already inserted.
Finding the inserted range again means reading the caret back through
Accessibility, and `docs/PHASE_4.md` already found that unreliable in exactly
the applications that need the fallback most. A replacement that lands in the
wrong place is worse than no replacement.

## Where the indicator lives

Two places, because one is not enough and the reasons differ.

- **The menu bar symbol** becomes `exclamationmark.triangle` while a result is
  worth checking. It is the only surface that is on screen whatever the user is
  doing, and it persists until they open the review, decline it, or dictate
  again.
- **A chip** appears for three seconds where the review panel used to, then
  fades. The menu bar is far from where the user is looking; the chip is not.
  Fading is the app being quiet, not the app forgetting — the triangle stays lit
  behind it.

The chip shares one panel with the clipboard-fallback notice, because they land
in the same corner at the same moment and two panels would draw on top of each
other. A successful insertion with nothing flagged still shows nothing at all.

## What this costs in audio lifetime

Phase 3 bounded the recording's life by the review decision and Phase 4 promised
to add no reason to hold it longer. Phase 5 does add one, and it is stated
rather than smuggled: a result worth checking keeps its samples, because the
review it offers may replay a fragment and the review now happens later, if at
all.

The bound is still a bound. The samples are released at whichever of these comes
first: the review is closed, the indicator is dismissed unopened, or the next
utterance begins. A result the policy prices as quiet releases them immediately,
as before. Nothing is written to disk at any point.

## Explicit non-goals

- Editing text already in the target application, including replacing what was
  just inserted. Unchanged from Phase 4 and reaffirmed above.
- Persistent history. Transcripts and audio stay memory-only.
- Bundling a dictionary. The four MVP languages are all in
  `NSSpellChecker.availableLanguages` on a stock Mac; a missing one switches the
  signal off rather than guessing.
- Making the entity heuristic smarter. It is priced correctly now, which is
  cheaper and more honest than a tagged model.

## Acceptance criteria

- No result of any kind delays insertion. A flagged result reaches the target
  application in the same time a quiet one does.
- A correctly recognized name never lights the indicator. Measured, not asserted:
  `ProseCorpus.withNames` reports an attention rate of 0, against 0.75 under the
  Phase 3 threshold.
- A malformed word does light it, on its own.
- A term in the user's dictionary is marked by nothing.
- Ordinary prose lights the indicator on at most a quarter of sentences.
- The recording is released by the close of the review, the dismissal of the
  indicator, or the start of the next utterance.

## What the measurement found, beyond the numbers

**The corpus could not see the problem.** `ProseCorpus` contained almost no
proper nouns, so the entity heuristic — the most frequently fired signal in a
real working day — measured as free. Eight sentences carrying correctly
recognized names were added, and the before/after is now an assertion rather
than a claim: 0.75 of them interrupted under the old threshold, 0 under the new
one.

**A latent crash was sitting in the panel's sizing.** `ReviewPanelController`
measures its SwiftUI content and sets the window to that size. `fittingSize` is
fractional whenever the content is, the frame a window settles on is
backing-aligned, and the two are then never equal — so the "only resize when it
changed" guard never fires and every layout pass resizes again, until AppKit
takes the app down. It had been dormant since Phase 4 and surfaced here for a
reason with no connection to any of this: the header icon changed from a
magnifying glass to a triangle, whose intrinsic height is not a whole number of
points. The app now crashed on the first press of "Show raw transcript".

The icon frame is pinned and the comparison rounds and tolerates sub-point
differences. Both are recorded in the code where someone changing them will read
them. `NSHostingController` with `sizingOptions` was tried as a replacement for
the whole mechanism and crashed harder, which is consistent with what
`docs/PHASE_4.md` says about the panel's first implementation.

## Measurement

Ordinary prose, 64 sentences, no speech engine — the hypothesis is the
reference, so every mark is a false warning by construction.

| Language | Samples | Words | Marks | Marks/100 words | Indicator |
| --- | ---: | ---: | ---: | ---: | ---: |
| de | 16 | 162 | 5 | 3.1 | 19 % |
| en | 16 | 161 | 5 | 3.1 | 19 % |
| ru | 16 | 122 | 6 | 4.9 | 19 % |
| uk | 16 | 117 | 6 | 5.1 | 19 % |
| **all** | **64** | **562** | **22** | **3.9** | **19 %** |

By signal: 18 number, 4 date. **Nothing else fires at all** — no entity, no
malformed word, no glossary, no cleanup edit, no language switch. The indicator
is now lit by amounts and dates and by nothing else on correct text, which is
the product promise and not a heuristic.

The malformed-word signal is measured with its dictionary gate removed
(`ShapeOnlyLexicon`), so the figure above is a strict upper bound: the shipping
app, which also consults the system dictionary, can only mark fewer.

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS' -only-testing:LocalDictationTests/ProseWarningDensityTests
```
