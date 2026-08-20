# LocalDictation

Native, local-first macOS dictation app. The product goal is fast voice input with a verifiable result: risky numbers, names, and uncertain fragments should be visible instead of being silently polished away.

## Current state

Phase 1 (application and audio foundation) is complete: menu bar lifecycle, microphone permission handling, a global push-to-talk hotkey, bounded in-memory PCM capture normalized to mono Float32 at 16 kHz, an energy-based voice-activity boundary, developer diagnostics, and a deterministic test suite.

Phase 2 (transcription and raw dictation) is complete. The engine is decided: **WhisperKit**. Apple's on-device engine was dropped because it cannot serve German, Russian, or Ukrainian offline on a stock Mac — it offers server recognition instead, which this product does not allow. Accuracy is **not** settled: the only measurements so far come from a synthesized smoke corpus, and no real speech has been scored. See `docs/PHASE_2_BENCHMARK.md`.

Phase 3 (uncertainty and conservative cleanup) is complete: conservative cleanup with an auditable edit map, six risk signals over the raw text, risky spans mapped onto the cleaned text, an explicit review policy, the review strip with raw-transcript recovery and memory-only fragment replay, and a user dictionary scoped by language.

Phase 4 (system insertion and app compatibility) is complete. The text leaves the app: Accessibility onboarding, a `TextInsertionService` that writes into the focused element, pastes where it cannot, and copies to the clipboard where it cannot do that either.

Phase 5 (verification that does not interrupt) is complete, and it came from using the app rather than from a plan. The review used to stand in front of the text and wait to be answered, and it was answering the wrong question: a correctly recognized product name was marked as risky in sentence after sentence, while `проверка` coming back as `ррверка` went through unmarked. Both are fixed, and the review no longer blocks anything. See `docs/PHASE_5.md`.

Three Phase 5 decisions are worth knowing before reading the code:

- **Insertion never waits for anybody.** The words go where you were typing, every time, and the checking is offered afterwards to whoever wants it. A risk mark that blocks the text costs the user on every utterance and pays back only on the rare one that is wrong; a mark that waits costs nothing. Frequent warnings are also what teaches people to dismiss warnings, and then the one that mattered goes with the rest.
- **Two thresholds, not one.** A capitalized word mid-sentence is worth an underline inside a review you opened on purpose. It is not worth a triangle. The high threshold is the only number that can cost you attention; the low one only decides what the review draws once you are already looking.
- **A word that is not a word is the strongest deterministic signal there is.** It is the one error you cannot catch by rereading your own sentence. But "not in the dictionary" was measured and rejected: macOS does not know `деплой`, `коммит`, or `аутентификация`, and marking those would have moved the noise rather than removed it. A word must be *impossible in shape* **and** unknown before it is marked.

Three Phase 4 decisions are worth knowing before reading the code:

- **The target is captured when recording starts, not read when inserting.** Transcription takes seconds and a review takes as long as reading does, so the frontmost application at the end is not reliably the one you spoke into. If you moved to a different application, the app does not guess — the text goes to the clipboard and says so. Inside the application you dictated into it goes wherever the caret is. A wrong target is the worst outcome available here: text meant for a document lands in a message that sends on Return, or a terminal that runs it.
- **The review panel does not take focus.** It is a non-activating panel, so the application you were typing in stays frontmost and the caret stays where you left it. Activating and then restoring focus was rejected: restoring focus across Electron and browser fields is unreliable, and a lost caret is a lost insertion point.
- **A password field is a refusal, and the clipboard is not a consolation prize.** With secure input enabled or a secure field focused, nothing is inserted and nothing is copied. Everywhere else, "your text is on the clipboard" is a normal result with its own sentence, not an error.

Two Phase 3 decisions are worth knowing before reading the code:

- **The deterministic signals come first and model confidence comes last.** Numbers, dates, amounts, names, dictionary near-misses, cleanup edits, and language switching are facts about the text. Model confidence is wired up and measured but carries a weight of **zero**, because Phase 2 found weak — and on Russian, negative — separation between the confidence of correct and incorrect tokens. It earns a weight from a measurement on real speech, not from an assumption.
- **A dropped word is not chased.** If the engine swallows "не" or "nicht", no rule can flag what is absent. The app does not build a mechanism for it; the reasoning is recorded in `docs/PHASE_3.md`. The consequence is that audio replay is offered only for a marked fragment, and the recording is discarded the moment the app decides no review is needed.

There is deliberately no analytics, licensing, or updater yet. The user dictionary is the only thing that persists — transcripts and audio stay in memory.

Read these files before continuing implementation:

- `docs/PRODUCT_SCOPE.md` — current product decisions and MVP boundary.
- `docs/ARCHITECTURE.md` — target architecture and phase boundaries.
- `docs/PHASE_1.md` — acceptance criteria for the first implementation phase.
- `docs/PHASE_2.md` — acceptance criteria for the previous phase.
- `docs/PHASE_2_BENCHMARK.md` — engine candidates, metrics, and how to run the benchmark.
- `docs/PHASE_3.md` — acceptance criteria for the previous phase.
- `docs/PHASE_3_MEASUREMENT.md` — how recall, false-warning density, and semantic preservation are measured, and what they came out as.
- `docs/PHASE_4.md` — acceptance criteria for the current phase.
- `docs/PHASE_4_MEASUREMENT.md` — what the review costs on ordinary prose, and what that measurement changed.
- `docs/PHASE_4_COMPATIBILITY.md` — which applications take text by which method.
- `docs/PHASE_5.md` — why the review stopped interrupting, and what it cost.
- `AGENTS.md` — repository-level engineering constraints.

## Requirements

- Apple Silicon Mac.
- Full Xcode installation, not only Command Line Tools.
- macOS 14.4 or newer as the deployment target.
- Swift 6 language mode with complete strict concurrency.

## Open and run

1. Open `LocalDictation.xcodeproj` in Xcode.
2. Select the `LocalDictation` scheme and `My Mac` destination.
3. In Signing & Capabilities, choose a Personal Team if Xcode requires one for local execution. A paid Apple Developer Program membership is not required for local development.
4. Build and run, then open the menu bar item and grant microphone access.
5. Choose a language profile and press **Prepare speech model…**. The first run downloads roughly 600 MB of Whisper weights into `~/Library/Application Support/LocalDictation/Models`. This is the only network access in the app, it is a one-way fetch of a static asset, and it never runs without this explicit action.
6. Hold `⌥Space` to record, release to finish. The text goes into whatever you were typing in, immediately and always. If something is worth a second look, a triangle appears in the menu bar and a small chip fades in and out where you are already looking — click either to see what was marked, or ignore both.
7. The first insertion asks for Accessibility access. Until it is granted, results are copied to the clipboard instead. **A development build loses this permission on every rebuild**, because macOS keys the grant to the code signature — expect to re-grant it after each build from Xcode.
8. Optionally add names and terms you dictate often under **Settings → Dictionary**. A word that comes out close to one of them, but not equal to it, gets marked.

The app is an agent-style menu bar utility (`LSUIElement = true`), so it does not show a Dock icon.

## Build and test from the command line

```sh
xcodebuild build -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
xcodebuild test  -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
```

## Module layout

```text
LocalDictation/
  Application/            app entry point and AppKit delegate
  Features/Dictation/     DictationCoordinator, the orchestration state owner
  Features/MenuBar/       menu bar UI and pure status presentation
  Features/Settings/      settings and developer diagnostics
  Models/                 recording state machine, utterance, diagnostics
  Services/Permissions/   microphone authorization boundary
  Services/Hotkey/        global push-to-talk hotkey boundary
  Services/Audio/         capture, format conversion, bounded PCM buffer
  Services/VAD/           replaceable voice-activity detector
  Services/Transcription/ TranscriptionService boundary and engine adapters
  Services/Text/          word scanning, edit distance, language evidence
  Services/Cleanup/       conservative cleanup and the edit map
  Services/Risk/          the six risk signals and the engine combining them
  Services/Review/        the review policy and decision
  Services/Glossary/      the user dictionary and its only persistence
  Features/Review/        review strip, its pure presentation, and the floating panel
  Benchmark/              corpus loading, scoring, and risk measurement (Debug builds only)
  Support/                logging and locking primitives
Tools/
  generate_pbxproj.py     regenerates the Xcode file lists from the files on disk
```

After adding or removing a source file, either add it in Xcode or run:

```sh
python3 Tools/generate_pbxproj.py
```

## Dependencies

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) 1.1.0, MIT. The only third-party dependency. Rationale in `docs/PHASE_2_BENCHMARK.md`: no system framework at the macOS 14.4 deployment target returns the per-word confidence Phase 3 is built on.

## Privacy

Audio stays in memory. Normal capture performs no file writes, and a test asserts that the real capture path creates no files. Inference is local; no audio or text is transmitted.

A recording's lifetime is bounded by the review decision, not by the end of the interaction: it is released the instant the app decides no review is needed, and otherwise when the review is accepted, dismissed, or superseded. Tests assert both. Replay reads those samples straight out of memory — no file and no URL is involved.

The user dictionary in `~/Library/Application Support/LocalDictation/glossary.json` is the only thing written to disk. It holds terms and their language, and a test asserts nothing else can end up in it.

Insertion adds one place text goes and one thing the app reads. The text goes into the application you were dictating into, or onto the clipboard, and nowhere else. The app reads a single character before the caret, to decide whether a leading space is needed; it is used and dropped inside that call. Neither is ever logged. What may appear in a log line is the target's bundle identifier and how the insertion went, because compatibility cannot be debugged without them — and a test asserts nothing derived from the utterance travels with them.

The single network operation is the explicit, user-initiated speech-model download. The debug WAV export is compiled only in Debug builds and writes solely to a location chosen by the user in a save panel.

## Distribution later

The public build will be distributed from the product website, not through the Mac App Store. Before external testing it must be signed with Developer ID, use Hardened Runtime, and be notarized. Stripe licensing and release automation are outside Phase 1.
