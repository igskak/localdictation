# LocalDictation

Native, local-first macOS dictation app. The product goal is fast voice input with a verifiable result: risky numbers, names, and uncertain fragments should be visible instead of being silently polished away.

## Current state

Phase 1 (application and audio foundation) is complete: menu bar lifecycle, microphone permission handling, a global push-to-talk hotkey, bounded in-memory PCM capture normalized to mono Float32 at 16 kHz, an energy-based voice-activity boundary, developer diagnostics, and a deterministic test suite.

Phase 2 (transcription and raw dictation) is in progress. Implemented: the `TranscriptionService` boundary, explicit language profiles, transcripts with per-token timing and confidence, two engine adapters, in-app raw transcript display with an explicit copy action, and the benchmark harness.

The engine is decided: **WhisperKit**. Apple's on-device engine was dropped because it cannot serve German, Russian, or Ukrainian offline on a stock Mac — it offers server recognition instead, which this product does not allow. Accuracy is **not** settled: the only measurements so far come from a synthesized smoke corpus, and no real speech has been scored. See `docs/PHASE_2_BENCHMARK.md`.

There is deliberately no text cleanup, risk highlighting, Accessibility insertion, persistence, analytics, or licensing yet. Text never enters another application: the only way it leaves the app is the copy button.

Read these files before continuing implementation:

- `docs/PRODUCT_SCOPE.md` — current product decisions and MVP boundary.
- `docs/ARCHITECTURE.md` — target architecture and phase boundaries.
- `docs/PHASE_1.md` — acceptance criteria for the first implementation phase.
- `docs/PHASE_2.md` — acceptance criteria for the current phase.
- `docs/PHASE_2_BENCHMARK.md` — engine candidates, metrics, and how to run the benchmark.
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
6. Hold `⌥Space` to record, release to finish, and the raw transcript appears in the menu bar panel.

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
  Benchmark/              corpus loading and scoring (Debug builds only)
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

Audio stays in memory. Normal capture performs no file writes, and a test asserts that the real capture path creates no files. Transcripts are memory-only and are discarded when the next utterance starts. Inference is local; no audio or text is transmitted.

The single network operation is the explicit, user-initiated speech-model download. The debug WAV export is compiled only in Debug builds and writes solely to a location chosen by the user in a save panel.

## Distribution later

The public build will be distributed from the product website, not through the Mac App Store. Before external testing it must be signed with Developer ID, use Hardened Runtime, and be notarized. Stripe licensing and release automation are outside Phase 1.
