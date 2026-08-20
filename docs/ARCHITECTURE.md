# Target architecture

## Runtime pipeline

```text
Global hotkey
  -> microphone permission
  -> audio capture (memory only)
  -> voice activity detection
  -> local STT with token metadata and timestamps
  -> language-aware risk engine
  -> conservative cleanup with an auditable edit diff
  -> map risky source spans onto the cleaned transcript
  -> Accessibility insertion
  -> clipboard fallback
  -> ReviewCoordinator decision, in parallel with the insertion
       -> nothing above the attention threshold: silent, and the audio is released
       -> something above it: light the indicator and hold the audio for replay
  -> review strip, only if the user asks for it: risky spans, raw text,
     and ephemeral audio replay
```

## Component boundaries

- `HotkeyService`: registers and unregisters global shortcuts and emits press/release events.
- `MicrophonePermissionService`: owns the macOS authorization state and the route to System Settings.
- `AudioCaptureService`: produces bounded, mono PCM frames without disk persistence.
- `VoiceActivityDetector`: classifies speech boundaries and exposes deterministic configuration.
- `TranscriptionService`: returns text plus token-level timing and confidence metadata.
- `RiskEngine`: combines model confidence, language switching, entities, numbers, glossary matches, malformed words, and cleanup edits.
- `LexiconChecking`: answers whether a word exists in a language, behind a protocol so the signals stay pure and the measurement stays machine-independent.
- `CleanupService`: performs conservative, reversible editing and returns an edit map.
- `ReviewCoordinator`: prices a result's marks against two thresholds — one that decides whether the app points at anything, one that decides what the review draws once opened. Insertion never waits for it.
- `TextInsertionService`: uses Accessibility first and clipboard as a fallback.
- `ActivationService`: exchanges a required email for a license key without creating a product account and enforces the five-dictation/24-hours-from-first-successful-dictation activation window.
- `TrialService`: evaluates a fourteen-day full trial and exposes deterministic trial and paywall states. The MVP has no post-trial free tier or weekly usage meter.
- `LicenseService`: evaluates annual and lifetime entitlements for up to two Macs without requiring a product account.
- `ProductTelemetryService`: emits only the allowlisted non-content activation, funnel, paywall, and checkout events documented in the privacy policy. It must not accept audio, text, vocabulary, application names, or content-derived values.

All service boundaries should be protocols with injected implementations. The UI owns orchestration state on `@MainActor`; audio callbacks and inference must stay off the main actor.

## Delivery phases

### Phase 1 — application and audio foundation

Menu bar shell, permission handling, global hotkey, in-memory PCM capture, simple VAD boundary, tests, and diagnostics. No STT.

### Phase 2 — transcription benchmark and raw dictation

Benchmark candidate engines on DE, EN, RU, and UK corpora. Integrate the winning baseline and return token timestamps/confidence. Show raw transcript inside the app; do not insert into other apps yet.

### Phase 3 — uncertainty and conservative cleanup

Implement the language-aware risk engine, entity/number rules, user glossary, cleanup edit mapping, confidence calibration, and the pre-insertion review strip with raw transcript recovery and memory-only fragment replay.

### Phase 4 — system insertion and app compatibility

Add Accessibility onboarding, insertion adapters, clipboard fallback, and the compatibility matrix for native apps, browsers, Electron editors, IDEs, and protected fields. Direct insertion is preferred but never promised for every target; the review step remains inside LocalDictation.

### Phase 5 — verification that does not interrupt

Split the risk policy into an attention threshold and a display threshold, insert unconditionally, and move the review behind an indicator the user may ignore. Add the malformed-word signal, which is what the review was missing.

### Phase 5 — licensing and release

Add required email-key activation, the fourteen-day full trial, the in-app paywall, Stripe Managed Payments checkout with Stripe acting as Merchant of Record, annual/lifetime entitlements, two-device activation, the allowlisted non-content product telemetry, Developer ID signing, notarization, and a signed update channel. General release diagnostics remain local unless explicitly shared by the user. Verify Stripe Managed Payments availability and product eligibility in the project account before implementing checkout.

## Non-negotiable quality metrics

- Silent critical error rate for numbers, dates, money, names, and negation.
- Recall of real critical errors by the risk engine.
- False-warning density.
- Semantic preservation after cleanup.
- End-of-speech to usable-result latency.
- Total user time including review and correction.
- Separate quality and calibration results for every supported language profile.
