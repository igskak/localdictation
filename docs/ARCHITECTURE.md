# Target architecture

## Runtime pipeline

```text
Global hotkey
  -> entitlement (ungated window, trial, or license — refused before the
     microphone opens, never after the words are spoken)
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
- `EntitlementPolicy`: the commercial rules as a pure function of a usage record, a verified license, and a date — the ungated five-dictation/24-hour window, the fourteen-day trial, and the expiry of a dated license. No clock, no disk, no network.
- `LicenseKey` and `LicenseAuthority`: the signed key format and its offline verification against a compiled-in Ed25519 public key. A license is checked here and nowhere else; there is no call home in the checking path.
- `EntitlementService`: holds the licensing state of this Mac and is the only thing that may change it. Re-derives the verdict rather than caching it, so a license that lapses while the app is open is noticed without a relaunch.
- `EntitlementStore`: persists the usage record — the second and last thing the app writes to disk.
- `DeviceIdentityProviding`: the salted hash of the hardware UUID that makes "two Macs" countable without holding a cross-product identifier.
- `ActivationBackend`: the one call the app may make to a server — an email address and the device hash in, a signed key out. Unimplemented until there is a service; the shipped default refuses rather than pretending.
- `ProductTelemetryService`: emits only the allowlisted non-content activation, funnel, paywall, and checkout events documented in the privacy policy. The event type is an enum with no free-form string in it, so there is nothing for audio, text, vocabulary, application names, or content-derived values to be passed to. Nothing is transmitted until a collector exists.

All service boundaries should be protocols with injected implementations. The UI owns orchestration state on `@MainActor`; audio callbacks and inference must stay off the main actor.

## Delivery phases

### Phase 1 — application and audio foundation

Menu bar shell, permission handling, global hotkey, in-memory PCM capture, simple VAD boundary, tests, and diagnostics. No STT.

### Phase 2 — transcription benchmark and raw dictation

Benchmark candidate engines on DE, EN, RU, and UK corpora. Integrate the winning baseline and return token timestamps/confidence. Show raw transcript inside the app; do not insert into other apps yet.

### Phase 3 — uncertainty and conservative cleanup

Implement the language-aware risk engine, entity/number rules, user glossary, cleanup edit mapping, confidence calibration, and the pre-insertion review strip with raw transcript recovery and memory-only fragment replay.

### Phase 4 — system insertion and app compatibility

Add Accessibility onboarding, insertion adapters, clipboard fallback, and the compatibility matrix for native apps, browsers, Electron editors, IDEs, and protected fields. Direct insertion is preferred but never promised for every target; the review step remains inside Witness.

### Phase 5 — verification that does not interrupt

Split the risk policy into an attention threshold and a display threshold, insert unconditionally, and move the review behind an indicator the user may ignore. Add the malformed-word signal, which is what the review was missing.

### Phase 6 — licensing and release

Add required email-key activation, the fourteen-day full trial, the in-app paywall, Stripe Managed Payments checkout with Stripe acting as Merchant of Record, annual/lifetime entitlements, two-device activation, the allowlisted non-content product telemetry, Developer ID signing, notarization, and a signed update channel. General release diagnostics remain local unless explicitly shared by the user. Verify Stripe Managed Payments availability and product eligibility in the project account before implementing checkout.

The local half is built: the rules, the signed key format and its offline verification, the entitlement gate inside the dictation state machine, the enumerated telemetry, and the interface. Three things wait on decisions outside the code — the activation service, the Stripe checkout, and an Apple Developer Program membership for signing and notarization. `docs/PHASE_6.md` records what was decided; `docs/PHASE_6_RELEASE.md` records the release path, none of which has been run.

## Non-negotiable quality metrics

- Silent critical error rate for numbers, dates, money, names, and negation.
- Recall of real critical errors by the risk engine.
- False-warning density.
- Semantic preservation after cleanup.
- End-of-speech to usable-result latency.
- Total user time including review and correction.
- Separate quality and calibration results for every supported language profile.
