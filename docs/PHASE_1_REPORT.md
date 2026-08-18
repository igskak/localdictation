# Phase 1 — implementation report

Status: implemented and verified with Xcode 26.6 on macOS 26.2 (Apple Silicon), except for the microphone-dependent manual checks listed at the end.

## What was built

The vertical slice from `docs/PHASE_1.md` is in place:

```text
⌥Space press → permission check → AVAudioEngine capture → mono Float32 16 kHz
→ bounded in-memory buffer + energy VAD → ⌥Space release → one utterance + diagnostics
```

25 source files across the module layout the phase document prescribes, plus 62 tests.

## Architectural decisions

- **Carbon `RegisterEventHotKey` for the global hotkey.** It is the only system API that delivers global key-down *and* key-up — which push-to-talk needs — without requiring Accessibility or Input Monitoring access. A `CGEventTap` would add a permission prompt that Phase 1 deliberately avoids. Registration collisions surface as `eventHotKeyExistsErr` and become a recoverable `.failed` state.
- **Pure state machine, side effects in the coordinator.** `RecordingStateMachine` rejects illegal events instead of silently applying them; `DictationCoordinator` owns all `@MainActor` orchestration and drives the injected services.
- **Polling instead of callbacks for live diagnostics.** The audio thread only writes into a lock-guarded sink; the UI reads a snapshot at 10 Hz. This keeps the real-time callback free of allocation, `Task` creation, and main-actor hops.
- **Bounded preallocated buffer.** `BoundedPCMBuffer` allocates `maximumUtteranceDuration × 16 kHz` frames once. Overflow is counted as dropped frames rather than growing memory.
- **Converter drain on stop.** `AVAudioConverter` holds back ~60 ms of resampler latency. Draining it after the tap is removed keeps the tail of what the user said; without it, roughly the last 940 frames of every utterance were silently lost.
- **Settings live in memory only.** Persistence is out of scope for Phase 1, so VAD thresholds reset on relaunch.
- **No third-party dependencies.** Carbon, AVFoundation, Core Audio, AppKit, SwiftUI, and OSLog cover every requirement.

## Verification

| Command | Result |
| --- | --- |
| `xcodebuild build … -configuration Debug` | BUILD SUCCEEDED, no warnings |
| `xcodebuild build … -configuration Release` | BUILD SUCCEEDED, no warnings |
| `xcodebuild test … -configuration Debug` | TEST SUCCEEDED, 62/62 passed |

Live application check: the Debug build starts as a menu bar utility (`LSUIElement`, no Dock icon), registers `⌥Space` without collision, and unregisters it deterministically on termination.

Verified on real hardware with a physical microphone (unified log trace):

```text
needsPermission → (explicit user action) → authorized → ready
ready → starting → Capture started: input 48000 Hz 1 ch, output 16000 Hz mono, capacity 1920000 frames
recording → finishing → Capture finished: 2.70 s, 43200 frames, dropped 0, reason hotkeyRelease → ready
second utterance: 2.40 s, 38400 frames, dropped 0
```

43 200 frames ÷ 16 000 Hz = 2.70 s exactly, which confirms the normalized mono Float32 16 kHz output on a 48 kHz input device, with no dropped frames and exactly one utterance per press/release. The permission dialog appeared only after the explicit menu action, never at launch.

Test coverage by area: state transitions and illegal events (11), coordinator with fake permission/hotkey/audio services (13), bounded PCM buffer and sink (7), format conversion and drain on generated buffers (7), VAD thresholds/start/trailing silence/maximum duration (11), status copy (7), WAV encoding (3), no-disk-writes and boundedness (3).

The privacy test runs the real converter + sink + detector path over synthetic buffers and asserts that no file appears in any directory the app can write to without user interaction. TCC-protected folders are deliberately excluded: probing them raises a macOS file-access dialog, which tests must never trigger.

## Not verified — needs a human at the keyboard

These still require a person at the keyboard:

1. A ten-minute stress session of repeated short recordings, watching for memory growth.
2. Unplugging or switching the input device mid-recording.
3. Revoking access in System Settings while the app runs, then the denied → Privacy Settings → re-check loop.
4. Listening to an exported debug WAV to confirm it sounds correct.

Verified interactively on 2026-08-18: launch and menu bar lifecycle, the explicit permission request and its approval, push-to-talk capture of real speech, one utterance per press/release, and the diagnostics section.

## Known limitations

- Trailing silence is reported but never ends a recording: push-to-talk release is the boundary. Only the maximum-duration cap stops capture on its own.
- The energy VAD is a deterministic baseline behind the `VoiceActivityDetector` protocol, not a production detector.
- Hotkey registration succeeds even while microphone access is denied; pressing it in that state is rejected by the state machine and leaves the actionable permission UI in place.
