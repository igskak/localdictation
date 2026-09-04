# Witness

Native, local-first macOS dictation app. The product goal is fast voice input with a verifiable result: risky numbers, names, and uncertain fragments should be visible instead of being silently polished away.

The product ships as **Witness**, at `witnessmac.com`. The Xcode project, the scheme and the source directories are still called `LocalDictation` — that is the working title this was built under, kept because renaming a target buys nothing a user can see. What a user does see — the app, its bundle identifier `com.witnessmac.Witness`, and the folder it keeps things in — says Witness.

## Current state

Phase 1 (application and audio foundation) is complete: menu bar lifecycle, microphone permission handling, a global push-to-talk hotkey, bounded in-memory PCM capture normalized to mono Float32 at 16 kHz, an energy-based voice-activity boundary, developer diagnostics, and a deterministic test suite.

Phase 2 (transcription and raw dictation) is complete. The engine is decided: **WhisperKit**. Apple's on-device engine was dropped because it cannot serve German, Russian, or Ukrainian offline on a stock Mac — it offers server recognition instead, which this product does not allow. Accuracy is **not** settled: the only measurements so far come from a synthesized smoke corpus, and no real speech has been scored. See `docs/PHASE_2_BENCHMARK.md`.

Phase 3 (uncertainty and conservative cleanup) is complete: conservative cleanup with an auditable edit map, six risk signals over the raw text, risky spans mapped onto the cleaned text, an explicit review policy, the review strip with raw-transcript recovery and memory-only fragment replay, and a user dictionary scoped by language.

Phase 4 (system insertion and app compatibility) is complete. The text leaves the app: Accessibility onboarding, a `TextInsertionService` that writes into the focused element, pastes where it cannot, and copies to the clipboard where it cannot do that either.

Phase 5 (verification that does not interrupt) is complete, and it came from using the app rather than from a plan. The review used to stand in front of the text and wait to be answered, and it was answering the wrong question: a correctly recognized product name was marked as risky in sentence after sentence, while `проверка` coming back as `ррверка` went through unmarked. Both are fixed, and the review no longer blocks anything. See `docs/PHASE_5.md`.

Phase 6 (licensing and release) is complete on the side that lives in this repository: the trial, the ungated window, activation, offline license verification, the paywall, and the enumerated product events. The client half of the activation call is written and tested against a stub server, so turning it on is one URL. Three things wait on decisions outside the code — the activation service itself, the checkout, and an Apple Developer Program membership for signing and notarization. `docs/PHASE_8.md` specifies all three and the order to take them in; see also `docs/PHASE_6.md` and `docs/PHASE_6_RELEASE.md`.

Phase 7 (the languages a person actually speaks) is complete. The eight
combinations the product used to offer are gone: the user names the languages
they speak, at first run, from every language the engine knows, and every
utterance is decoded as one of them and never as one that was not chosen.
German, English, Russian, and Ukrainian remain the verified tier — the rest are
recognized, and the rules calibrated per language stay off rather than guess.
See `docs/PHASE_7.md`.

After Phase 6, a round of refinements closed the gaps between what the app
promised and what it did. The app now says something when a dictation comes back
empty, names the application holding secure input, keeps the words when a
microphone changes mid-sentence, records in either of the two modes the scope
has always listed, lets the shortcut be changed, and opens at login. See
`docs/REFINEMENTS.md`.

Six refinement decisions are worth knowing before reading the code:

- **Silence is an answer, and the app owes the user one.** A press that
  recognized nothing inserted nothing, needed no review, and said nothing at
  all — which is indistinguishable from a hotkey that did not work. It now says
  which of the two silences it was: a microphone that never reached speech level
  names the input device, and speech that came back empty names the language
  profile it was asked in.
- **A name is the action.** "An application has secure input enabled" describes
  a problem to someone with thirty applications open and gives them nothing to
  do about it. The app now asks the window server who is holding the flag.
- **A changed microphone does not take back words already said.** The rule Phase
  6 wrote for a trial running out mid-utterance is the same rule here. The
  recording ends where the device went away, but it ends the way a released key
  ends it: finished, transcribed, delivered, and the reason said afterwards
  rather than instead.
- **⌥Space is a default, not a law.** Carbon offers no way to ask whether a
  combination is free, so the change path is built around failing: the working
  shortcut goes back the instant a new one is refused. A shortcut with no
  modifier is refused before it reaches the system, because registering one
  takes a bare key away from every application on the Mac.
- **Two recording modes are not two preferences about one thing.** Push-to-talk
  is a key held for the length of a sentence; toggle is two presses around a
  paragraph. Nobody holds a key for four minutes.
- **Settings that do not survive a launch are not settings.** So there is a
  third file in Application Support beside the dictionary and the licensing
  record. It is JSON, readable, six fields, and a test asserts the list.
- **A locked Mac no longer opens the microphone, and the press is where the
  price is named.** `.locked -> .locked` read as a successful transition, so a
  press after the trial ended started a recording nothing could stop. The
  precondition is now checked before the microphone, and the press that finds
  the Mac locked brings up the offers instead — `paywall_shown` moved to the
  window that draws them, so the event means a person saw a price rather than a
  Mac having quietly locked in the background.

Five Phase 6 decisions are worth knowing before reading the code:

- **A license is a signature, not a phone call.** The app carries a public key and checks a license locally, so a bought copy works on a plane, behind a proxy, and after this project's servers are gone. The cost is named rather than hidden: a key cannot be revoked remotely.
- **A lock never costs you a sentence you have already said.** A trial that runs out mid-utterance lets that utterance finish, transcribe, and land in the document. The press *after* it is the one that is refused. The licensing precondition lives beside the recording state rather than inside it, which is what makes both true at once.
- **What you pay a dictation for is text you received.** A press that recognized nothing does not come out of your five. Two real utterances of nine and ten seconds came back empty while Phase 4 was being measured; charging for those would be indefensible.
- **The wall is announced before it arrives.** The menu says how many ungated dictations are left once the first one has been spent, and says that a trial ends before it ends. Someone who discovers a licensing window by pressing the hotkey and getting nothing has been surprised by their own software; the countdown lives where they already look rather than only on a settings page nobody opens to find out something is about to break.
- **The record on disk is plain, and that is a decision.** `license.json` is six readable fields beside the dictionary. Obfuscating it would buy a product that lies to its owner about what it stores; the real defence is that editing it can hand you a few more days of trial and can never hand you a license.

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

There is deliberately no updater and nothing is transmitted. The user dictionary, the licensing record, and the settings file are the only things that persist — transcripts and audio stay in memory.

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
- `docs/PHASE_6.md` — the trial, the key format, and what is deliberately not built yet.
- `docs/PHASE_8.md` — the activation service, the checkout, and the release, as one specification with the wire contract frozen.
- `docs/PHASE_6_RELEASE.md` — signing, notarization, and the update decision. None of it has been run.
- `docs/REFINEMENTS.md` — what the app now says when a dictation produces nothing, who is named when insertion is refused, and the three settings that reach disk.
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
5. The first launch asks which languages you speak. Pick as many as you use — there is nothing to switch between afterwards, and **Settings → Languages** changes it later. Then press **Prepare speech model…**. The first run downloads roughly 600 MB of Whisper weights into `~/Library/Application Support/Witness/Models`. This is the only network access in the app, it is a one-way fetch of a static asset, and it never runs without this explicit action.
6. Hold `⌥Space` to record, release to finish. The text goes into whatever you were typing in, immediately and always. If something is worth a second look, a triangle appears in the menu bar and a small chip fades in and out where you are already looking — click either to see what was marked, or ignore both. If a press comes back with no text at all, the app says which of the two silences it was rather than saying nothing.
7. The first insertion asks for Accessibility access. Until it is granted, results are copied to the clipboard instead. **A development build loses this permission on every rebuild**, because macOS keys the grant to the code signature — expect to re-grant it after each build from Xcode.
8. The menu carries one per-session choice: *Any of RU+EN+UK*, or *Only Russian* for the hour you spend on one document. It is never written to disk. Under **Settings → General** you can change the shortcut, switch to pressing it twice instead of holding it, and have the app open at login. The shortcut needs at least one of `⌘ ⌥ ⌃ ⇧`; a combination something else already owns is refused and the working one stays. Opening at login needs the app to live in `/Applications` — macOS will not make a login item out of a build running from Xcode, and says so.
9. Optionally add names and terms you dictate often under **Settings → Dictionary**. A word that comes out close to one of them, but not equal to it, gets marked.
10. The first five dictations, or the first 24 hours from the first one, need no email and no key. After that, **Settings → License** is where a key is entered. Issue yourself one with `swift Tools/licensekit.swift issue --device <id> --email you@example.com --kind lifetime`, taking the identifier from **Settings → License → This Mac**. Signing requires the private key in `~/.localdictation/`; the public half is already compiled in, so any build of this repository accepts keys issued against it.

The app is an agent-style menu bar utility (`LSUIElement = true`), so it does not show a Dock icon.

## Build and test from the command line

```sh
xcodebuild build -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
xcodebuild test  -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
```

### Reclaiming build cache

Xcode names its `~/Library/Developer/Xcode/DerivedData` folder after the
absolute project path, so every checkout builds into its own tree — about
150 MB for a build, more once tests run. Repeated builds from the same path
reuse one folder and do not grow the total, but a deleted git worktree leaves
its tree behind forever. Prune the leftovers:

```sh
./Tools/prune_derived_data.sh           # list orphans
./Tools/prune_derived_data.sh --delete  # remove them
```

The model weights under `~/Library/Application Support/Witness/Models`
are a separate 1.5 GB and are not build output — deleting them means
downloading them again on next launch.

## Module layout

```text
LocalDictation/
  Application/            app entry point and AppKit delegate
  Features/Dictation/     DictationCoordinator, the orchestration state owner
  Features/Languages/     the language picker, shared by first run and settings
  Features/MenuBar/       menu bar UI and pure status presentation
  Features/Onboarding/    the first-run language question and its window
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
  Services/Glossary/      the user dictionary and its persistence
  Services/Preferences/   the shortcut, the mode, the languages, and where they live
  Features/Review/        review strip, its pure presentation, and the floating panel
  Features/Licensing/     the license page, its pure presentation, and the offer
  Services/Licensing/     entitlement rules, signed keys, the usage record, device identity
  Services/Telemetry/     the enumerated product events, transmitted nowhere
  Services/Launch/        whether the app opens at login
  Benchmark/              corpus loading, scoring, and risk measurement (Debug builds only)
  Support/                logging and locking primitives
Tools/
  generate_pbxproj.py     regenerates the Xcode file lists from the files on disk
  licensekit.swift        issues license keys; the private key never enters the repository
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

Three files in `~/Library/Application Support/Witness/` are the only things written to disk. `glossary.json` holds terms and their language; `license.json` holds an install identifier, when the first dictation happened, how many succeeded, the furthest date the app has seen, and the license key if there is one; `preferences.json` holds the shortcut's key code, modifiers, and label, the recording mode, the languages the user speaks, whether insertion is automatic, and whether the first-run language question has been answered. A test asserts the exact field list of each.

Nothing in `preferences.json` is derived from anything that was said. It is a settings file rather than a `UserDefaults` domain on purpose: everything this app writes belongs in one directory the user can open, and a preference the app will not show its owner is a preference the app is keeping from them.

Insertion reads one more thing than it used to. When it refuses because secure input is on, it asks the window server which process is holding the flag, so the refusal can name the application instead of describing a state. The name reaches the user; the log keeps the bundle identifier, as it does for the target.

Insertion adds one place text goes and one thing the app reads. The text goes into the application you were dictating into, or onto the clipboard, and nowhere else. The app reads a single character before the caret, to decide whether a leading space is needed; it is used and dropped inside that call. Neither is ever logged. What may appear in a log line is the target's bundle identifier and how the insertion went, because compatibility cannot be debugged without them — and a test asserts nothing derived from the utterance travels with them.

Two operations can reach the network, both user-initiated and neither carrying content: the explicit speech-model download, and pressing "Send me a key", which sends an email address and a salted hash of this Mac's hardware UUID to the activation service. Licensing itself is offline — a key is verified against a public key compiled into the app, so nothing is checked with a server at any point. Product events are enumerated in `docs/PHASE_6.md` and are currently transmitted nowhere. The debug WAV export is compiled only in Debug builds and writes solely to a location chosen by the user in a save panel.

## Distribution later

The public build will be distributed from the product website, not through the Mac App Store. Before external testing it must be signed with Developer ID, use Hardened Runtime, and be notarized. `docs/PHASE_6_RELEASE.md` is the checklist, and nothing on it has been run — Developer ID certificates need a paid membership.
