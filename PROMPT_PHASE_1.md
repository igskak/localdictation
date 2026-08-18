# Prompt: implement Phase 1

You are the principal macOS engineer for LocalDictation. Work directly in this repository and fully implement Phase 1: the native application and audio foundation.

Before changing code, read completely:

1. `AGENTS.md`
2. `README.md`
3. `docs/PRODUCT_SCOPE.md`
4. `docs/ARCHITECTURE.md`
5. `docs/PHASE_1.md`

Treat those documents as the source of truth. Inspect the current project and installed toolchain before choosing implementation details. Preserve the existing product constraints and do not broaden the phase.

## Outcome

Deliver a reliable local vertical slice:

```text
Option+Space press
  -> explicit microphone permission flow
  -> microphone capture
  -> mono Float32 16 kHz bounded memory buffer
  -> deterministic energy-based VAD state
  -> Option+Space release
  -> one completed in-memory utterance with diagnostics
```

There is deliberately no STT, text cleanup, risk highlighting, Accessibility insertion, persistence, networking, analytics, licensing, model download, or updater in this phase.

## Engineering requirements

- Use native Swift 6, SwiftUI/AppKit, AVFoundation/Core Audio, and system APIs.
- Keep UI/orchestration state on `@MainActor`; never block or allocate unbounded memory in the real-time audio callback.
- Put OS integrations behind protocols and inject them into the coordinator.
- Model recording as an explicit state machine with legal transitions and recoverable errors.
- Request microphone access only after a clear user action. Handle all authorization states and provide a button that opens the correct System Settings page when denied.
- Implement an isolated global hotkey adapter. Default to push-to-talk on `Option + Space`; report registration collisions instead of failing silently.
- Normalize input to mono Float32 PCM at 16 kHz and keep it in a bounded in-memory buffer. Make the maximum utterance duration explicit.
- Implement a replaceable `VoiceActivityDetector` protocol with a deterministic energy/RMS baseline. Track speech start and trailing silence, but never trim frames destructively in Phase 1.
- Add privacy-safe diagnostics for device, formats, duration, peak level, buffer use, dropped frames, VAD state, and errors. Never log samples or save audio automatically.
- If a debug WAV export is useful, compile it only in Debug, require an explicit save-panel action, and test that ordinary capture performs no file writes.
- Keep the app sandbox disabled. Do not add third-party packages unless a system API cannot satisfy a requirement; explain and document any exception before adding it.

## Tests

Add deterministic tests that do not need a microphone or OS permission dialog for:

- recording state transitions and invalid events;
- the coordinator with fake permission, hotkey, and audio services;
- bounded PCM buffer behavior;
- format normalization/conversion on generated sample buffers;
- VAD thresholds, speech start, trailing silence, and maximum duration;
- recovery from hotkey registration and audio capture failures.

## Verification

Use the available full Xcode toolchain. Build and run the complete test suite with `xcodebuild`. Then perform the safe manual checks from `docs/PHASE_1.md`, including denied permission, repeated short recordings, and input-device interruption where possible. Do not claim a manual check you could not perform.

If full Xcode is missing, stop before implementation that cannot be verified, report the exact toolchain blocker, and provide the shortest installation/selection instructions. Do not rewrite the project into a different build system to work around a missing Xcode installation.

Finish only when the Phase 1 acceptance criteria are satisfied or clearly identify the remaining blocker. In the final report, lead with the outcome, list important architectural decisions, show the verification commands and results, and call out any unverified manual behavior.

