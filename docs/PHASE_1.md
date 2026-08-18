# Phase 1 — application and audio foundation

## Objective

Produce a reliable local vertical slice from global hotkey input to a bounded in-memory utterance. Phase 1 ends before speech recognition. Its output is validated PCM audio plus diagnostics that later phases can consume.

## Required behavior

### Menu bar lifecycle

- Launch as a menu bar utility without a Dock icon.
- Expose clear states: permission required, ready, recording, processing boundary, denied, and recoverable failure.
- Provide Settings, Quit, and a route to the appropriate macOS privacy settings when access is denied.

### Microphone permission

- Read current authorization without triggering a dialog during object initialization.
- Request access only after a deliberate user action.
- Handle authorized, denied, restricted, and not-determined states.
- Never crash or enter a recording state without authorization.

### Global hotkey

- Default to push-to-talk on `Option + Space`.
- Register and unregister deterministically.
- Surface collisions or registration failure.
- Make the hotkey adapter replaceable and test the coordinator with a fake implementation.

### Audio capture

- Use `AVAudioEngine` or an equally justified native API.
- Convert microphone input to mono Float32 PCM at 16 kHz.
- Keep audio in a bounded in-memory buffer only.
- Do not allocate unbounded memory or perform blocking work in the audio callback.
- Expose duration, sample count, peak level, and dropped-frame diagnostics.
- Stop cleanly on hotkey release, device loss, permission change, or application termination.

### Voice activity boundary

- Implement a small protocol and a deterministic energy-based baseline; it is a replaceable boundary detector, not the final production VAD.
- Track speech start, trailing silence, and maximum utterance duration.
- Do not remove speech frames from the captured utterance.
- Make thresholds configurable and unit-test the pure logic.

### Developer diagnostics

- Show current input device, input sample rate, normalized output format, utterance duration, and VAD state inside a debug section.
- Provide an explicit debug-only export action if listening to a sample is necessary. It must require a user action, write to a user-selected location, and never run in normal capture.
- Use privacy-safe structured logging; never log PCM data.

## Suggested module layout

```text
LocalDictation/
  Application/
  Features/MenuBar/
  Features/Settings/
  Services/Permissions/
  Services/Hotkey/
  Services/Audio/
  Services/VAD/
  Models/
```

Moving the existing scaffold into this layout is part of Phase 1.

## Acceptance criteria

- The app builds and tests successfully with the repository's Xcode project.
- After permission approval, holding `Option + Space` records and releasing it completes exactly one utterance.
- A ten-minute stress session of repeated short recordings does not freeze or grow memory without bound.
- Denying permission produces actionable UI and no crash.
- Disconnecting or changing the microphone produces a recoverable state.
- Captured output is verified as mono Float32 PCM at 16 kHz.
- No recording is written to disk during normal operation.
- State-machine, hotkey-coordinator, PCM-buffer, converter, and VAD baseline tests pass without requiring a physical microphone.
- No STT, model download, network request, analytics, Accessibility insertion, or Stripe code is introduced.

## Completion report

The implementer must report:

- files and architecture introduced;
- commands run and their results;
- manual permission/hotkey/audio checks performed;
- known hardware or macOS limitations;
- any acceptance criterion that remains unverified.

