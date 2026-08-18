# LocalDictation

Native, local-first macOS dictation app. The product goal is fast voice input with a verifiable result: risky numbers, names, and uncertain fragments should be visible instead of being silently polished away.

## Current state

Phase 1 (application and audio foundation) is implemented: menu bar lifecycle, microphone permission handling, a global push-to-talk hotkey, bounded in-memory PCM capture normalized to mono Float32 at 16 kHz, an energy-based voice-activity boundary, developer diagnostics, and a deterministic test suite.

There is deliberately no speech recognition, model download, text cleanup, Accessibility insertion, persistence, networking, analytics, or licensing yet.

Read these files before continuing implementation:

- `docs/PRODUCT_SCOPE.md` — current product decisions and MVP boundary.
- `docs/ARCHITECTURE.md` — target architecture and phase boundaries.
- `docs/PHASE_1.md` — acceptance criteria for the first implementation phase.
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
5. Hold `⌥Space` to record and release to complete one utterance.

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
  Support/                logging and locking primitives
Tools/
  generate_pbxproj.py     regenerates the Xcode file lists from the files on disk
```

After adding or removing a source file, either add it in Xcode or run:

```sh
python3 Tools/generate_pbxproj.py
```

## Privacy

Audio stays in memory. Normal capture performs no file writes, and a test asserts that the real capture path creates no files. The debug WAV export is compiled only in Debug builds and writes solely to a location chosen by the user in a save panel.

## Distribution later

The public build will be distributed from the product website, not through the Mac App Store. Before external testing it must be signed with Developer ID, use Hardened Runtime, and be notarized. Stripe licensing and release automation are outside Phase 1.
