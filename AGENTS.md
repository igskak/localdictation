# Repository instructions

## Product constraints

- Content processing is strictly local-first. Never send audio, transcripts, vocabulary, clipboard contents, application contents, risky fragments, or other content-derived data to a remote service.
- The app may send only explicitly enumerated non-content product and marketing events plus minimal technical metadata required for activation, licensing, funnel measurement, payments, and updates. Every transmitted field, purpose, recipient, and retention period must be disclosed in the privacy policy and the relevant product terms. General diagnostics remain local unless the user explicitly opts in to sharing them.
- Supported MVP speech languages are German, English, Russian, and Ukrainian.
- Verification is a core product promise. Never hide uncertain recognition or semantic rewrites behind a polished result.
- Audio is memory-only by default. Do not persist recordings unless a later requirement explicitly introduces an opt-in feature.

## Engineering constraints

- Use native Swift, SwiftUI, AppKit, AVFoundation, Core Audio, and other Apple frameworks where they fit.
- Target Apple Silicon and macOS 14.4 or newer.
- Use Swift 6 concurrency checks. UI state belongs on `@MainActor`; real-time audio callbacks must not block or hop onto the main actor.
- Prefer protocols and small injected services around permissions, hotkeys, audio capture, VAD, STT, cleanup, review, insertion, and licensing.
- Do not add a third-party dependency unless the standard frameworks cannot satisfy the phase requirement. Document the license and rationale before adding one.
- Do not add STT, ML models, Accessibility insertion, persistence, networking, analytics, licensing, or update frameworks during Phase 1.
- Keep the app sandbox disabled for the direct-distribution architecture unless a later decision explicitly changes it.
- Never commit signing certificates, provisioning profiles, recordings, downloaded model weights, or user-specific Xcode state.

## Quality bar

- Add deterministic unit tests for state transitions and pure audio/VAD logic.
- Keep system APIs behind adapters so tests do not trigger OS permission dialogs or require a microphone.
- Treat denied and restricted permissions as normal states with actionable UI.
- Verify the Xcode project with `xcodebuild` after every implementation slice when full Xcode is available.
- Preserve unrelated user changes.
