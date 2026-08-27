# Phase 7 — the languages a person actually speaks

## Objective

Stop asking the user to pick one of eight combinations the product decided for
them, and let them name the languages they speak — once, at first run, from
every language the engine knows.

```text
first run
  -> "which languages do you speak?"  [x] German  [x] English  [x] Russian
                                      [ ] … 96 more
  -> every utterance is decoded as one of those, chosen from the engine's own
     ranking, never as a language the user did not name
```

Nothing about the recognition model changes. Whisper already ranks all hundred
languages on every mixed-profile utterance and the app already throws away the
ranking outside the selected pair — this phase widens what "selected" is allowed
to mean and makes the choice out of that ranking explicit, ordered, and
testable.

## Why this is not a feature request for "more languages"

The four MVP languages were never a limit of the engine. `large-v3-turbo`
carries all hundred; `docs/PRODUCT_SCOPE.md` named four because four is what the
benchmark, the cleanup rules, and the risk signals were built and measured
against. That distinction survives this phase rather than being erased by it:

- **Verified** — German, English, Russian, Ukrainian. Recognition, conservative
  cleanup, and every risk signal, measured in `docs/PHASE_2_BENCHMARK.md` and
  `docs/PHASE_3_MEASUREMENT.md`.
- **Available** — the other ninety-six. Recognition, plus the rules that rest on
  something this product did not have to measure: whitespace and punctuation
  spacing, a script mismatch, an acronym, a capital letter in a language that
  capitalizes only names. Filler removal, the malformed-word rule, and the
  letter-level language evidence are calibrated per language and are switched
  off rather than guessed at.

A product whose promise is "never hide uncertain recognition" cannot quietly
serve a language whose uncertainty it does not know how to mark. So the two
tiers are visible in the picker, and the degradation is deliberate, tested
behaviour rather than an accident of a missing dictionary entry.

## The decisions worth reading before the code

### A profile is a set, not a pair

`LanguageProfile` held `primary` and an optional `secondary`, and eight
combinations were enumerated as static values. It now holds an ordered,
deduplicated, non-empty list of languages. Everything the rest of the app asks
it — `primary`, `languages`, `contains`, `isMixed`, `displayName`, `shortLabel`,
`id` — answers the same way, so the risk engine, the glossary, the benchmark,
and the transcript keep compiling against a type whose meaning widened
underneath them.

Order is not cosmetic. The first language is the **preferred** one: the fallback
when the engine has no opinion, and the tie-break when it has two. A user who
speaks Russian, English, and Ukrainian, and whose work is mostly Russian, is
saying something real by putting Russian first.

### The identifier and the file both stay readable

A profile's `id` is its codes joined with `+` — `de+en`, `ru+en+uk` — which is
what the old two-language identifier already looked like, so benchmark corpora
that name a profile keep working unchanged.

`preferences.json` now stores `{"languages": ["ru", "en", "uk"]}`. A file
written by an older build stores `{"primary": "ru", "secondary": "en"}`, and the
decoder reads both. This is not politeness: a silent reset would take away the
choice this phase exists to give, and the user would find out by dictating a
sentence in the wrong language.

### Detect once, then pin, instead of decode and hope

The old mixed path decoded with free language detection, noticed afterwards if
Whisper had wandered outside the profile, and then detected and decoded a second
time. The wandering was real — a Ukrainian utterance came back as Polish in
Latin script, which is what `LanguageClampTests` was written for — but the shape
of the fix was a retry.

The new path asks for the language distribution first, decides which language
the utterance is in, and decodes once with that language pinned. Two things
follow. The decode can no longer produce a language the user did not select, at
all, rather than being corrected when it does. And the decision becomes a pure
function of a probability table, which means it can be tested without a model.

The cost is one extra encoder pass on mixed profiles, against a saved full
decode whenever the old path had to retry. Single-language profiles skip
detection entirely, as before.

### Two languages that sound alike need more than an argmax

Restricting Whisper's ranking to the selected languages fixes drift *out* of the
set. It does nothing about confusion *inside* it, which is the failure a
Russian-and-Ukrainian user actually meets: a two-word answer carries barely more
than a second of evidence, and the ranking is a coin toss between two closely
related languages.

`LanguageDecision` therefore takes three inputs — the distribution, the profile,
and the language of the previous utterance — and applies rules in this order:

1. One language selected: pinned, no detection.
2. No selected language appears in the distribution: the preferred one.
3. The leader is ahead of the runner-up by at least the margin: the leader.
4. Otherwise the utterance is ambiguous. If the previous utterance's language is
   one of the two leaders and was recent, it wins — a person mid-paragraph is
   still in the same language. Failing that, if the preferred language is one of
   the two leaders, it wins. Failing both, the leader.

The margin and the recency window are constants with a comment explaining what
they are for, not tuned values: they start at 0.2 and two minutes, and
`docs/PHASE_2_BENCHMARK.md`'s harness is what moves them.

The rule that is deliberately absent is stickiness that outlives evidence. A
confident distribution always wins over the previous language, so switching
languages mid-session costs one clear sentence, never a setting.

### Only Continue answers the question

This was decided the other way first, and one live launch was enough to
disprove it. The reasoning had been that the app has always had a language
profile, so there is nothing to cancel into and the red button may as well
record what is on screen.

What that missed is that a window can be closed without ever having been read.
The app is an accessory with no Dock icon: its one question can open behind a
full-screen editor or on another Space, and be closed by someone tidying their
screen. On the first real launch that is exactly what happened — German and
English were recorded, which the user had never chosen, and the question was
never asked again.

So closing records nothing and the next launch asks again, the window opens
floating and on the active Space, and the log says which of the two happened.
A question that can be answered by accident is not a question.

### The engine may be told one language for a while, without changing the set

The menu carries a temporary pin: *Auto*, or one of the selected languages.
Pinning is not a preference and is not written to disk — it is for the hour
someone spends writing one German document, and it is gone at the next launch.
The set the user chose stays the thing the app remembers.

### The unverified ninety-six degrade in named places

- Filler removal already keys off a per-language table and finds nothing.
- The malformed-word rule is off entirely. Not only its consonant-run test: the
  vowel table it judges shape against is Latin-basic plus the German umlauts and
  the Ukrainian і/ї/є, so Polish `łódź` reads as a word with no vowel in it. Half
  a rule aimed at the wrong alphabet is worse than none.
- The name heuristic's "a capital letter mid-sentence is a name" rule assumes a
  language that does not capitalize its nouns. That is now a property of the
  language — German and Luxembourgish capitalize — rather than `!= .german`, and
  it is the one heuristic an unverified language keeps.
- `LanguageIdentifier` proves a language switch from script and from letters
  that exist in one language of a pair and not the other. Both are meaningful
  only for Latin and Cyrillic; a profile naming a language in any other script
  reports no evidence rather than a wrong one.

## What changes, file by file

| File | Change |
| --- | --- |
| `Models/SpeechLanguage.swift` | New. The type, backed by the catalog, no longer an enum of four. |
| `Models/LanguageCatalog.swift` | New. One hundred languages: code, English and native name, script, verified flag, whether the language capitalizes nouns. Generated from the engine's own list. |
| `Models/LanguageProfile.swift` | An ordered set of languages; the eight old combinations survive as named values. |
| `Models/Preferences.swift` | Stores the set; gains `hasChosenLanguages`; decodes older files. |
| `Services/Transcription/LanguageDecision.swift` | New. The pure decision described above. |
| `Services/Transcription/WhisperKitTranscriptionService.swift` | Detect once, decide, decode pinned; remembers the previous language. |
| `Services/Risk/*`, `Services/Text/LanguageIdentifier.swift` | Degradation for unverified languages and non-Latin, non-Cyrillic scripts. |
| `Features/Onboarding/*` | New. The first-run picker and the window that carries it. |
| `Features/Settings/*` | A Languages tab; the dictionary scopes its picker to the chosen languages. |
| `Features/MenuBar/MenuBarView.swift` | The eight-profile picker becomes the selected set plus the temporary pin. |

## Acceptance criteria

- A first run with no settings file opens the picker, and a settings file from
  a Phase 6 build opens it too — a stored default is not an answer. Dictation is
  not blocked behind it: the question has a valid answer on screen from the
  moment it appears, and on a first run there are no model weights to dictate
  with anyway.
- The picker offers every language the engine knows, separates the four verified
  ones, and refuses to leave the user with none selected.
- Closing the window records nothing, and the next launch asks again. Only
  Continue answers.
- A `preferences.json` written by a Phase 6 build keeps its languages.
- With one language selected, no language detection runs at all.
- With several selected, the decoded language is always one of them — asserted
  over a distribution where an unselected language outranks every selected one.
- An ambiguous distribution continues the previous utterance's language when
  that language is one of the two leaders and the previous utterance was recent,
  and falls back to the preferred language when it is not.
- A confident distribution overrides both.
- The temporary pin survives no launch and is never written.
- An unverified language dictates, and the signals that are not calibrated for
  it stay silent instead of guessing.
- The settings file holds seven fields and nothing else.

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
```

## What is still open

- **The margin and the recency window are unmeasured.** They are reasonable and
  they are constants in one place; a mixed-language corpus is what turns them
  into numbers.
- **The verified tier does not grow in this phase.** Polish is the obvious next
  one — `docs/PRODUCT_SCOPE.md` has listed it as post-MVP since the first draft —
  and promoting a language means a corpus, filler and title tables, and a
  measured false-warning rate, not a flag.
- **Nothing biases the decoder toward the user's vocabulary.** `DecodingOptions`
  carries `promptTokens`, and the dictionary the user already maintains is the
  obvious thing to put in it. It is not in this phase because Whisper's prompt
  conditioning also invents the words it is given, and shipping that without the
  measurement would trade silent misrecognitions for silent inventions.
