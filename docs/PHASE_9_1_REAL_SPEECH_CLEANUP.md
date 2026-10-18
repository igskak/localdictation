# Phase 9.1 — Real-speech normalization and structural Clean

Status: **planned after the implemented Phase 9 pipeline**.

## Objective

Make the deterministic cleanup pipeline work on the text Whisper actually
produces in live dictation, then use its existing word timings to turn longer
speech into readable sentences, paragraphs, and lists without paraphrasing.

This phase deliberately separates three promises:

```text
Whisper transcript
  -> exact preserved raw                         Verbatim
  -> surface canonicalization                    Conservative
  -> speech cleanup and document structure       Clean
  -> grammar, rewording, tone, and concision      future Polish phase
```

Phase 9 built the transformation, provenance, protected-span, context, and
release-gate foundations. Phase 9.1 hardens those foundations against real
Whisper output and adds structural inference. It does not introduce a language
model and does not widen the privacy boundary.

## Why this is the next step

The Phase 9 text fixtures use canonical phrases. Live Whisper output is less
regular even when recognition is semantically correct:

- a compound marker may arrive with a detached hyphen;
- a percentage may contain a space before `%`;
- punctuation may be emitted as a symbol in one recording and as a spoken word
  in another;
- punctuation may surround a correction or list marker;
- fillers and immediate repetitions may already have been removed by Whisper;
- different recordings of the same dictated phrase may produce different raw
  transcripts.

The current Clean rules therefore succeed on part of an utterance while missing
its structure. Adding more exact-string rules directly to each transformer
would repeat normalization logic and still leave sentence and paragraph
formatting dependent on Whisper's inconsistent punctuation.

Word timings already exist in `TranscriptToken`, and WhisperKit is already
decoded with `wordTimestamps: true`. Phase 9.1 should use that evidence rather
than introduce a second speech model or infer every boundary from text alone.

## Mode contracts

### Verbatim

Verbatim remains an identity operation over `Transcript.text`.

- no canonicalization;
- no whitespace repair;
- no capitalization;
- no structural inference;
- exact raw recovery remains possible.

The raw transcript and raw token ranges are never mutated to make later stages
easier.

### Conservative

Conservative fixes representation, not intent. Its output must preserve the
recognized lexical content under a closed surface-equivalence table, apart
from the existing filler vocabulary and a separately proven
duplicate-at-segment-boundary repair.

Allowed:

- whitespace collapse and punctuation spacing;
- sentence-initial capitalization and terminal punctuation already provided by
  `ConservativeCleanupService`;
- locale-safe spacing for `%`, currency symbols, degrees, and known units;
- closed, language-keyed compound repair such as a detached hyphen in a known
  list marker;
- canonical Unicode forms for dashes, apostrophes, and quotation marks only
  where the direction of the replacement is unambiguous;
- duplicate removal only when overlapping Whisper timing evidence proves the
  same segment-boundary token was emitted twice.

Not allowed:

- interpreting `colon`, `двоеточие`, or another spoken command;
- turning ordinal words into a list;
- deleting a correction marker or false start;
- adding inferred internal punctuation or paragraph breaks;
- changing a number's value or replacing a word with a synonym;
- grammar repair.

The implementation must keep `ConservativeCleanupService` as the reusable
primitive and add a composed user-facing Conservative pipeline around it. This
preserves the old implementation as a benchmark control while intentionally
updating the product contract.

### Clean

Clean produces ready-to-use structure without changing the user's chosen
wording.

In addition to the implemented Phase 9 behavior, it may:

- recognize command, correction, and list markers after Conservative
  canonicalization and around harmless punctuation;
- infer sentence boundaries from token gaps plus language-specific lexical
  evidence;
- infer paragraph boundaries from long pauses and completed clause evidence;
- build a list without a literal colon when a measured introductory pattern and
  at least two sequential markers are present;
- apply category-specific structural policy, such as shorter paragraphs in a
  chat and preserved final punctuation in a document;
- normalize the typography of values Whisper already rendered as digits.

Clean may remove only a named class of speech material: a measured filler,
explicit correction span, proven immediate repetition, or explicit list marker.
It must not select synonyms, repair agreement, reorder clauses, summarize, or
invent greetings, conclusions, or connective words.

### Future Polish mode

Polish is not part of Phase 9.1. It begins when wording can change:

- grammar and agreement repair;
- rephrasing for clarity;
- shortening and deduplication across non-adjacent clauses;
- topic-based restructuring;
- tone or application style that changes words;
- sentence or paragraph reordering.

That work requires a separate local-model evaluation, download and license
decision, memory and latency budgets, a protected-fact verifier, visible diff,
and fallback to Clean. Polish must initially be explicit opt-in and must never
silently replace Clean as the safety fallback.

## Non-negotiable invariants

1. **Raw remains exact.** Every later representation is derived from the stored
   raw transcript; the raw string and its token ranges are never overwritten.
2. **Local only.** Audio, timings, transcript text, surrounding field text, and
   learned rules never leave the Mac.
3. **No new persistence.** Timings and structural candidates live only for the
   active dictation. Phase 9.1 adds no transcript or audio history.
4. **Conservative is lexically stable.** After applying the same closed
   surface-equivalence table to both sides, its word sequence equals raw apart
   from enumerated fillers and a timing-proven boundary duplicate.
5. **Clean does not paraphrase.** Every removed word belongs to an allowed edit
   kind, and every inserted character is punctuation, whitespace, list syntax,
   value rendering, or a user-authored dictionary replacement.
6. **Protected facts survive.** Numbers, dates, times, amounts, units,
   negations, glossary terms, and entity candidates retain Phase 9 protection.
7. **Timing is optional evidence.** Missing, malformed, or non-monotonic token
   timings disable inferred structure and fall back to text-only Phase 9 Clean.
8. **Precision wins.** An uncertain boundary remains unchanged. Recall is
   measured but cannot justify a semantic punctuation error.
9. **Unsupported languages remain Conservative.** Structural rules ship only
   after independent DE/EN/RU/UK measurement.
10. **Every edit remains attributable.** Canonicalization and inferred
    structure gain closed edit kinds and participate in the exact composed map.

## Target pipeline

```text
CapturedUtterance
  -> Whisper Transcript { raw text, word ranges, word timings, confidence }
  -> preserve exact raw
  -> RealWhisperCanonicalizer
       whitespace / symbols / closed compound variants /
       timing-proven segment-boundary duplicates
  -> ConservativeCleanupService
  -> protected-span projection
  -> implemented Phase 9 Clean transformers
       commands / dictionary / explicit corrections / repetitions /
       typed values
  -> StructuralBoundaryPlanner
       sentence candidates / paragraph candidates
  -> RobustListTransformer
  -> sentence and typography finalization
  -> ContextCompositor with application-category structure policy
  -> RiskEngine over raw evidence and every edit
  -> unconditional insertion with raw recovery
```

The canonicalizer runs before every non-Verbatim mode. Spoken commands remain a
Clean concern: canonicalization may repair the written form of a command phrase,
but Conservative never executes it.

## Core implementation

### `CleanupTimingEvidence`

Pass only the evidence cleanup needs rather than the entire transcription
service model:

```swift
struct CleanupTokenTiming: Sendable, Equatable {
    let rawRange: Range<Int>
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
}

struct CleanupTimingEvidence: Sendable, Equatable {
    let tokens: [CleanupTokenTiming]
}
```

Add optional timing evidence to `CleanupOptions` or to a new value-type cleanup
input. Keep the existing string-only convenience entry point for pure tests and
callers; it supplies no timing evidence and preserves existing fallback
behavior.

Validation occurs once at the boundary:

- ranges are ordered, non-empty, and inside raw text;
- times are finite, non-negative, and `start <= end`;
- token order is monotonic;
- invalid evidence is discarded as a whole rather than partially trusted.

The coordinator snapshots timings with the same utterance as cleanup level and
context. No timing enters preferences, logs, telemetry, or persisted review
state.

Timing ranges always remain anchored to raw. Before a timing-aware stage runs,
project both neighboring token anchors through the accumulated `EditMap` into
the current string. If an earlier deletion consumed an anchor, two anchors
cross, or projection is ambiguous, reject that boundary candidate. Do not
rewrite timing ranges after every stage and do not recover them by diffing.

### `RealWhisperCanonicalizer`

Implement a pure transformer that returns `CleanupResult` and composes into the
existing edit map.

Its rules are closed and ordered:

1. normalize whitespace and punctuation adjacency already understood by the
   old Conservative service;
2. repair symbol spacing (`20 %`, `25 €`, `12 : 30`) only when the complete
   surrounding span parses as that value;
3. repair known compounds and list markers using per-language tables;
4. normalize a small explicit Unicode equivalence table;
5. remove a boundary duplicate only with overlapping or near-identical token
   timing evidence and exact normalized token equality.

Do not implement a general `word -word -> word-word` rule. A dash may be
intentional. Do not reinterpret punctuation words here. Do not normalize an
identifier, URL, email address, filesystem path, or glossary term unless a rule
owns and validates the complete span.

Add edit kinds such as `surfaceNormalization` and `boundaryDuplicateRemoval`
instead of reporting these as generic spacing or repetition when their evidence
and risk are different. Structural inference likewise uses distinct
`inferredPunctuation` and `inferredParagraphBreak` kinds so review and benchmark
reports never confuse an automatic boundary with an explicit spoken command.

### `ConservativePipeline`

Create a small composed service:

```text
RealWhisperCanonicalizer
  -> ConservativeCleanupService
  -> exact EditMap composition
```

The old service stays independently testable. Add a benchmark switch that can
compare legacy Conservative, new Conservative, and Clean over the same raw
text. Preferences continue to store `.conservative`; no migration is needed.

### `StructuralBoundaryPlanner`

The planner proposes punctuation and line breaks; it never rewrites words.
Each candidate records:

- raw anchor;
- proposed boundary: comma, sentence, or paragraph;
- timing gap;
- lexical and punctuation evidence;
- application-category policy, if available;
- confidence bucket and named rule identifier.

Initial rule family:

- preserve explicit punctuation and explicit spoken commands first;
- never insert inside a protected or identifier-like span;
- reject boundaries adjacent to abbreviations, decimals, dates, times, URLs,
  email addresses, or initials;
- consider a sentence boundary only after a measured token gap and a complete
  clause-shaped span of minimum length;
- use `.` as the inferred terminator unless an explicit command or existing
  Whisper punctuation supplies `?` or `!`;
- consider a paragraph only after a stronger gap, a completed preceding
  sentence, and non-trivial text on both sides;
- do not infer topic changes from word meaning in this phase.

Thresholds must not be guessed into production. Put candidate thresholds in a
single language policy and choose them from the consented real-speech corpus.
Unit tests may use explicit fixture thresholds, while production policies stay
disabled for a language until its measurement report exists.

### `RobustListTransformer`

Extend the Phase 9 list transformer after canonicalization:

- accept canonical and measured Whisper variants of ordered markers;
- ignore harmless commas immediately before or after a marker;
- accept an existing colon, an explicit spoken colon command, or a measured
  introductory pattern followed by a pause;
- require at least two sequential markers;
- reject non-sequential and isolated ordinals;
- preserve item wording exactly;
- use timing boundaries to avoid consuming text after the list;
- retain plain-text output so insertion works in every field.

Examples such as "the first version" or "во вторник" remain literal. Every
marker needs a literal counterexample in each verified language corpus.

### Context policy

Phase 9 already captures bounded ephemeral context. Phase 9.1 may extend the
existing application categories with code/terminal and use the resulting
category to select structure policy:

- **chat:** prefer short blocks and omit a final period only under the existing
  safe context rule;
- **email/document:** keep complete sentences and allow paragraph inference;
- **code/terminal:** disable inferred paragraphs, lists, and punctuation beyond
  explicit commands;
- **unknown:** use the context-free measured default.

The category changes thresholds and presentation only. It cannot authorize a
wording change. Browser-site classification remains out of scope unless a
separate privacy and compatibility decision adds it.

## Implementation slices and commits

Every slice is one reviewable commit. Do not combine a failing slice with the
next one to make the history appear green.

### Slice 0 — contract, captured shapes, and baseline

1. Add synthetic text fixtures matching real Whisper output shapes without
   storing user dictation.
2. Record legacy Conservative and current Clean outputs.
3. Add lexical-sequence and idempotence scorers.
4. Record the Phase 9.1 baseline report.

Commit: `phase9.1: record real-whisper cleanup baseline`

Exit: fixtures reproduce detached compounds, symbol spacing, punctuation around
markers, timing gaps, and missing timing fallback; no production behavior has
changed.

### Slice 1 — Conservative surface canonicalization

1. Add `RealWhisperCanonicalizer` and closed per-language variant tables.
2. Add protected identifier/value guards.
3. Add `ConservativePipeline` and exact edit-map composition.
4. Route user-facing Conservative and the base of Clean through it.

Commit: `phase9.1: canonicalize real Whisper output`

Exit: Conservative repairs accepted surface variants while passing the lexical
preservation and raw-recovery suites in all verified languages.

### Slice 2 — timing evidence plumbing

1. Add cleanup timing value types and validation.
2. Pass projected `TranscriptToken` timing evidence from the coordinator.
3. Add missing, malformed, and non-monotonic fallback tests.
4. Prove timing values are absent from persistence, logs, and telemetry.

Commit: `phase9.1: pass ephemeral token timings to cleanup`

Exit: text-only behavior is byte-for-byte unchanged when timing is unavailable.

### Slice 3 — inferred sentence boundaries

1. Add `StructuralBoundaryPlanner` and language policies.
2. Implement high-precision sentence candidates and abbreviation guards.
3. Add closed edit kinds and risk/review presentation.
4. Measure candidate thresholds on private real speech before enabling each
   language.

Commit: `phase9.1: infer sentence boundaries from pauses`

Exit: enabled languages pass boundary precision and protected-value gates;
disabled languages retain Phase 9 behavior.

### Slice 4 — paragraph structure

1. Add paragraph candidates using stronger pause and completed-clause evidence.
2. Add chat, document/email, code/terminal, and unknown policies.
3. Preserve explicit new-line and new-paragraph commands as higher priority.
4. Add repeated-dictation and long-utterance tests.

Commit: `phase9.1: format clean dictation into paragraphs`

Exit: paragraph insertion improves blind preference without changing the word
sequence or firing in code and terminal fields.

### Slice 5 — robust lists and corrections

1. Accept canonicalized marker variants and harmless surrounding punctuation.
2. Add timing-bounded implicit list introduction.
3. Expand explicit correction-marker surface variants without adding implicit
   semantic restatement.
4. Add adversarial literal-use fixtures in every verified language.

Commit: `phase9.1: harden clean lists and corrections`

Exit: live-shaped list fixtures format correctly and literal-use precision meets
the release gate.

### Slice 6 — measurement, rollout, and documentation

1. Run legacy Conservative, new Conservative, Phase 9 Clean, and Phase 9.1
   Clean over the same fixtures and private corpus.
2. Run the manual application matrix and ten-minute soak.
3. Run a blind preference comparison against Conservative and a Wispr Flow
   reference set.
4. Update product scope, architecture, privacy wording, settings explanations,
   and the release-gate report.
5. Keep the fresh-install default Conservative until both Phase 9 and Phase 9.1
   gates pass together.

Commit: `phase9.1: record structural clean release evidence`

Exit: all automated and manual evidence is recorded; the default changes only
in a later explicit rollout commit if every gate passes.

## Test plan

### Canonicalization tests

- accepted detached-hyphen variants in DE/EN/RU/UK;
- literal dash and subtraction counterexamples;
- percent, currency, degree, time, and unit spacing;
- punctuation adjacent to commands and correction markers;
- URLs, emails, paths, identifiers, version strings, and decimal numbers;
- Unicode grapheme clusters and composed/decomposed forms;
- idempotence of every rule and the complete pipeline;
- exact raw-to-Conservative-to-raw range projection.

### Timing tests

- zero, short, sentence, and paragraph gap fixtures;
- overlapping, equal, missing, NaN, infinite, and decreasing timings;
- tokens whose range does not resolve in raw text;
- segment-boundary duplicate positive and negative cases;
- no structural inference when evidence validation fails;
- deterministic output independent of wall-clock execution.

### Structural tests

- abbreviations, initials, decimals, dates, times, URLs, and email addresses;
- explicit punctuation outranking inferred punctuation;
- explicit paragraph commands outranking automatic boundaries;
- questions and exclamations preserved but not guessed without evidence;
- lists with and without a colon, punctuation around markers, and trailing prose;
- isolated ordinal words and non-sequential markers remaining literal;
- code and terminal categories refusing inferred structure;
- unsupported languages matching new Conservative exactly.

### Invariant and property tests

- Verbatim equals raw exactly;
- Conservative lexical sequence, compared through the closed surface-equivalence
  table, equals raw after subtracting only declared filler and
  timing-proven boundary-duplicate edits;
- Clean output words are a subsequence/replacement set explainable entirely by
  allowed edit kinds;
- protected values and negations survive every stage;
- composed edit maps are monotonic and bounded;
- applying edits reproduces the exact final output;
- running any level twice is idempotent;
- missing timing or context produces the documented fallback.

### Manual verification

- natural long dictation in German, English, Russian, and Ukrainian;
- Notes, Mail, Messages, Slack, Teams, Gmail, Google Docs, Notion, TextEdit,
  Xcode, VS Code/Cursor, Terminal, and an Electron editor;
- empty field, mid-sentence continuation, selection replacement, and repeated
  dictation into the same paragraph;
- short chat, multi-paragraph note, email body, task list, and AI prompt;
- comparison of inserted Clean, raw recovery, and immediate undo;
- ten-minute repeated-dictation soak with no retained audio, timings, context,
  or transcript history.

## Release gates

Phase 9 gates remain in force. Phase 9.1 adds:

| Metric | Gate |
| --- | ---: |
| Raw identity and recovery | 100% |
| Conservative protected-value preservation | 100% |
| Conservative lexical preservation under declared surface equivalence | 100% |
| Canonicalization precision | >= 99.9% per verified language |
| Canonicalization idempotence | 100% |
| Sentence-boundary precision | >= 99.5% per enabled language |
| Paragraph-boundary precision | >= 99.0% per enabled language |
| List/correction precision | >= 99.5% per enabled language |
| Critical-fixture semantic preservation | 100% |
| Missing-timing fallback equality | 100% |
| Phase 9 regression gates | no regression |
| Phase 9.1 Clean preferred to new Conservative | >= 70% blind preference |
| Total p95 cleanup + context overhead | <= existing 75 ms Phase 9 budget |

Recall is reported for sentence, paragraph, list, and correction opportunities
but does not weaken the precision gates. Thresholds are per language; one
language passing never enables another.

## Expected files

New files, with final names adjusted to repository conventions if needed:

```text
LocalDictation/Services/Cleanup/
  RealWhisperCanonicalizer.swift
  ConservativePipeline.swift
  CleanupTimingEvidence.swift
  StructuralBoundaryPlanner.swift
  StructuralBoundaryPolicy.swift

LocalDictation/Benchmark/
  RealSpeechCleanupBenchmark.swift
  StructuralCleanupScorer.swift

LocalDictationTests/
  RealWhisperCanonicalizerTests.swift
  CleanupTimingEvidenceTests.swift
  StructuralBoundaryPlannerTests.swift
  StructuralCleanupInvariantTests.swift

docs/
  PHASE_9_1_BASELINE.md
  PHASE_9_1_RELEASE_GATE.md
```

Existing files expected to change:

```text
LocalDictation/Models/TextEdit.swift
LocalDictation/Models/Transcript.swift
LocalDictation/Services/Cleanup/CleanupService.swift
LocalDictation/Services/Cleanup/AdaptiveCleanupService.swift
LocalDictation/Services/Cleanup/ListTransformer.swift
LocalDictation/Services/Cleanup/ExplicitCorrectionTransformer.swift
LocalDictation/Services/Context/ApplicationCategory.swift
LocalDictation/Features/Dictation/DictationCoordinator.swift
LocalDictation/Services/Risk/CleanupEditRiskSignal.swift
LocalDictation/Features/Settings/SettingsView.swift
LocalDictation/Resources/Localizable.xcstrings
docs/PRODUCT_SCOPE.md
docs/ARCHITECTURE.md
docs/PRIVACY.md
docs/PHASE_9_RELEASE_GATE.md
README.md
```

After every Swift slice run `python3 Tools/generate_pbxproj.py` if new files were
added, then the relevant focused tests, the complete test suite, and the Release
build required by the repository instructions.

## Explicitly deferred

- grammar and agreement repair;
- synonyms, paraphrasing, summarization, and concision;
- topic-semantic paragraphing;
- tone presets that change wording;
- implicit correction by unrestricted restatement;
- automatic learning from edits in other applications;
- persistent transcript, context, timing, or audio history;
- browser-site classification;
- a second speech or punctuation model;
- any local generative model or remote processing;
- Polish-mode UI or model download.

These belong to a separate Polish-mode phase. Phase 9.1 should leave clean
interfaces and evidence for that work, not smuggle generative decisions into a
deterministic transformer.

## Acceptance criteria

- Verbatim still returns the exact Whisper transcript.
- Conservative repairs measured real-Whisper surface artifacts without
  interpreting commands, changing word choice, or building structure.
- Clean recognizes the measured live variants of commands, corrections, and
  lists.
- Clean can split a sufficiently evidenced long utterance into sentences and
  paragraphs without changing its wording.
- Missing timing evidence produces the text-only Phase 9 fallback.
- DE/EN/RU/UK enable independently from recorded evidence; every other language
  returns new Conservative behavior.
- Raw recovery, edit provenance, protected values, secure-field refusal, and
  local-only processing retain their existing guarantees.
- The fresh-install default remains Conservative until the combined release
  report proves every required Phase 9 and Phase 9.1 gate.
- Every implementation slice is committed separately and leaves the full
  repository test suite and Release build green.

## Phase after this one

Phase 10 may evaluate a local Polish mode. Its first deliverable is not UI or a
model download; it is a measured spike comparing candidate local models on
grammar improvement, protected-fact preservation, RAM, package size, energy,
and end-of-speech latency. No candidate proceeds unless it can fall back to
Clean on uncertainty and expose Clean and Verbatim recovery in the review.
