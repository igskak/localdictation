# Model selection in the local test build

This records prototype build 28. The staged-download flow for the next release
is documented in [MODEL_SELECTION.md](MODEL_SELECTION.md).

Based on the installed dogfood commit `51a7c09`. Settings → Speech model is
available in Debug and NOTETAKER_DOGFOOD builds. Choose a model, then Restart
Witness. The saved choice applies to both dictation and Notetaker after launch;
the active model remains visible while a different choice is pending.

Choices: Whisper large-v3 turbo (existing default), full Whisper large-v3,
Parakeet Ultra and Parakeet TDT v3. Nothing changes until a choice is made.
Full large-v3 uses the already benchmarked repository variant
`openai_whisper-large-v3_turbo`: despite its conversion folder name, its config
is `openai/whisper-large-v3` with 32 decoder layers. The turbo default is
`openai_whisper-large-v3-v20240930_turbo`.

Only one speech engine is constructed. Whisper retains per-caller language
context and its existing inference queue. Parakeet shares its loaded manager
and serializes dictation and meeting requests through the same FIFO primitive.
Unsupported language profiles are refused in both entry points. A missing
selected model uses the existing preparation/download flow; model weights stay
in Application Support, and audio stays in memory. No new dependencies,
telemetry or uploaded content are introduced. Cleanup and Nemotron diarization
are not changed by the selection.

Restart is unavailable during capture, transcription, insertion, an active or
finishing meeting. Switching away from a slow model preparation is allowed. The chosen model is persisted under
the existing local `DictationEngine` defaults key. Unknown values retain the
Whisper turbo default. This is a local test build, not a published release.

## Verification — 2026-11-16

- Xcode Debug suite: 1208 tests, 10 opt-in/corpus tests skipped, 0 failures.
- Release dogfood build and DMG verification passed; installed as 0.6.26 (28).
- Installed executable SHA-256 matches the packaged executable:
  `3fdaf72a096543a751113ad1d37e731fc63701bf8a392ea2ffb54c1f456f106f`.
- Model settings rendered in light/dark and all existing interface languages.
- The initial installed-model smoke run was interrupted after disk/swap
  pressure; it is not evidence of recognition accuracy or a completed model
  comparison. The optional tests remain off in the standard suite.

Test image: `build/Witness-test-model-selector-0.6.26-28.dmg`.
Previous installed app retained at `build/Witness-before-model-picker.app`.

Native UI verification: all four choices are present; selecting Parakeet Ultra
shows a pending restart without changing the active model; Restart Witness
launches a new process and the Settings page then reports Parakeet Ultra as
active. Left that process running because a 3.39-second dictation was captured
while its model was preparing; restarting again would discard memory-only
audio. The last observed menu status was waiting for the speech model.
