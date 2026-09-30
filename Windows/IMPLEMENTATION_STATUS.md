# Witness for Windows — implementation status

Last updated: 2026-09-30

This file is the source of truth for the Windows port. A phase is complete only
after its required Windows CI and artifact checks have run successfully. Local
cross-targeting on macOS is not reported as Windows validation.

## Baseline

- Product baseline: Witness `0.6.8` (build 9), Git commit
  `c073a8fbad5fe1cca7ef6dcf06fc7c19c2c89b77`.
- GitHub release status rechecked on 2026-09-27: `v0.6.8` was the latest
  published release, published 2026-09-24 18:18:12 UTC.
- The local checkout started at `f66081e59839c8af6bcfcddec64c8992fb0ad391`
  and contains unrelated user changes. The release source was inspected
  read-only through Git objects and an external temporary extraction; no Mac or
  Service source was changed by the Windows implementation.
- SHA-256 values for the release files used as behavioral references are stored
  in `config/mac-release-baseline.sha256`.

## Phase status

| Phase | Status | Completed in this checkout | Remaining gate |
| --- | --- | --- | --- |
| W0 | **Complete** | Pinned solution/toolchain/dependencies; Core and WPF shell; successful Windows CI and self-contained artifact; C ABI and real CPU-only RAM PCM-to-whisper smoke with segment timing; signed-manifest/verified-package spike; privacy endpoint inventory; build metadata; baseline hashes | Physical Windows/hardware claims remain intentionally outside W0 |
| W1 | **Complete** | Recording state machine and cancellation generation; bounded PCM buffer and energy VAD; complete engine language catalog, selection/pin/continuity policy; final-recording language timing guard; Unicode boundary map; conservative cleanup/edit map; all risk signals and release prose bounds; review thresholds/history rules; entitlement/lifetime pure policy; 76 tests passed on macOS and Windows | Windows system lexicon capability remains a W5 platform integration; physical speech accuracy remains W3/W8 |
| W2 | **Complete** | WPF tray lifecycle, named single-instance lease and non-activating activity badge; hold/toggle hotkeys and startup opt-in; preallocated packet queue and bounded fake-tested capture lifecycle; memory-only event-driven shared-mode WASAPI; PCM16/24/32/Float32 normalization; Media Foundation 44.1/48→16 kHz resampling with drain; opaque endpoint-ID enumeration with unknown built-in metadata kept explicit; microphone privacy recovery, local hotkey-to-capture preview and verified session-loss stop tests on Windows CI | Physical microphone/device/session QA remains W8 |
| W3 | **Complete** | Verified local model manager and disclosed download UX; immutable multilingual product-model candidate; cancellable native transcription/token bridge; grapheme word mapping with honest segment-timing fallback; real backend probe and one controlled CPU retry policy; completed-recording language-score bridge with VAD speech boundary; pinned synthetic eSpeak DE/EN/RU plus neural Piper UK leading-noise regression; test-only native benchmark; app-level verified-model → completed-audio language decision → explicit-language transcription flow with generation cancellation and immediate audio clearing; successful real-model CPU Windows CI | Physical GPU/laptop performance and real-speech accuracy remain W8 QA; hosted CPU timings are recorded below rather than generalized |
| W4 | **Complete** | PID + root-HWND capture at hotkey start; active-session/default-desktop and changed-target guards; bounded single-STA UIA protection/value/selection inspection; verified standard `Edit` selection replacement; one-shot modifier-gated paste; fail-closed protected clipboard formats and sequence-safe restore; generation/target/protection race coordinator; app-level hotkey → local transcript → insertion wiring; test-only accessible normal/password/delayed-paste harness | Real Word, Chrome and VS Code compatibility remains explicitly pending physical W8 QA; no universal-application claim is made |
| W5 | **In progress** | Cleanup/risk/review and RAM replay are connected to insertion; latest-ten RAM history excludes protected refusals; review audio has a bounded flagged-only lifetime; Windows dictionaries fail open per language capability; two-step onboarding, six navigable Settings sections, ordered language persistence, session-only glossary, audio-input selection, voice-boundary controls and key-parity EN/DE resources passed 63 Windows platform tests plus the privacy-scanned synthetic render harness | Complete physical Windows DPI/high-contrast/keyboard and screen-reader evidence before marking W5 complete |
| W6 | **In progress** | Pure entitlement timing/major policy; offline LD1 verifier and Service fixture parity; atomic local record; SMBIOS-derived Windows identity; fixed activation/release adapter; full License screen and pre-microphone entitlement gate; first-success trial start; local/remote removal; three-event consent/local-only telemetry; build-time isolated beta authority/endpoint inputs; bundled Windows beta terms/privacy drafts | Run this slice in Windows CI; provision the separate beta authority/service and protected build values; replace legal placeholders and obtain review before external distribution |
| W7 | Not started | Manifest/package verification spike and unsigned internal packaging workflow only | Manual updater state machine/UX, signed metadata production path, A-to-B install/update preservation test, uninstall/reinstall policy, signing gate |
| W8 | Not started | — | Installable closed-beta kit, checksum, notices with full license texts, release notes, known issues, tester guide/checklist/bug template, regression/soak/privacy evidence |

## Implemented contracts and checks

### Build and update foundation

- SDK: .NET SDK `10.0.401`; target `net10.0-windows10.0.26100.0`,
  Windows x64, self-contained publish.
- Managed test/build dependencies are centrally pinned and restored with lock
  files. Velopack CLI and SDK are pinned to `1.2.158`; NSec.Cryptography is
  pinned to `26.4.0`; MSTest is pinned to `4.4.1` with
  Microsoft.NET.Test.Sdk `18.10.1`.
- whisper.cpp is pinned to release `v1.9.4`, commit
  `927cfce34f31707e17f2bff35c349632fb9e2c3a`. The native build defaults to CPU;
  Vulkan is optional.
- The native boundary uses opaque context/result handles and explicit destroy
  calls. Input is in-memory mono Float32 PCM, transcription is bounded to 600
  seconds, translation is disabled, and C++ exceptions do not cross the ABI.
- Update metadata is Ed25519-verified over the exact decoded manifest bytes
  before JSON parsing. Validation binds schema, key ID, package/app ID,
  platform, architecture, channel, version/build, product major, minimum OS,
  URL allowlist, exact size and lowercase SHA-256. Only a full `.nupkg` is
  exposed to Velopack after download verification.
- Velopack startup integration explicitly disables automatic apply on startup.
  The current package workflow produces an **unsigned internal artifact only**.

### Pure Core parity already covered locally

- Busy recording/transcription/insertion state transitions, entitlement expiry
  during a phrase, capture interruption and stale callback generations.
- Bounded audio buffering, deterministic overflow behavior, VAD transitions,
  duration bounds and reset behavior.
- Selected-language clamp, temporary pin, previous-language continuity,
  decision margin and the rule that final language is committed only after the
  completed recording.
- Grapheme, UTF-16 and UTF-8 boundaries for Cyrillic, combining marks, emoji,
  CJK, CRLF and repeated words.
- Verified-language-only cleanup/risk calibration, conservative wording,
  negation/numbers, punctuation/whitespace/capitalization and cleanup edit maps.
- Review thresholds (`0.8` attention, `0.3` display), model-confidence weight
  zero, bounded session-only text history and exclusion of protected refusals.
- Number/amount/date, named-entity, glossary near-miss, malformed-word,
  language-switch, cleanup-edit and confidence signals; duplicate entity
  suppression, audio timing projection, verified-tier capability gates and the
  release prose budgets (at most 6 attention marks per 100 correct words and
  at most 25% of ordinary samples earning attention).
- Three-day local use, ten-day activated trial, annual/lifetime entitlements,
  clock rollback resistance and lifetime major-version coverage.

### W5 complete-user-path slice

- The first-run surface asks for an ordered non-empty subset of all 100 engine
  languages, explains the local hotkey/model/privacy path, and records
  completion only after the final action. The same selection editor remains
  available under Languages; ordering is preserved because the first language
  is the deterministic fallback for ambiguous or evidence-free phrases.
- The six Settings destinations are keyboard-reachable and functional for the
  current phase: General controls hold/toggle, current-user startup, microphone
  choice and model setup; Languages edits the engine profile; Boundary stages
  in-memory VAD tuning for the next capture; Dictionary owns session-only
  vocabulary; License accurately exposes the W6 gate without a fake activation;
  Diagnostics reports technical counts/capabilities without content.
- W5 persists only a versioned allowlist of non-content choices under local app
  data: onboarding completion, language codes, activation mode and audio-input
  selection. Atomic replacement and invalid-document fallback are injected and
  tested. Vocabulary is intentionally absent from the document and is cleared
  with the process.
- Audio input enumeration presents the Windows default and every active opaque
  endpoint. A missing selected endpoint resolves through the existing pure
  fallback policy and is reported; capture opens the resolved endpoint only at
  the next recording. Witness never changes the Windows system default.
- Session glossary additions are trimmed, language-scoped, duplicate-checked,
  bounded to 500 entries / 80 graphemes and passed into the same postprocessor
  that produces glossary near-miss review evidence. It has no persistence or
  networking surface.
- English and German resource dictionaries expose the same key and format-item
  sets, including runtime capture, transcription, insertion, review, error and
  accessibility messages rather than only static page labels. WPF uses
  system colors/fonts, visible field labels, 44-pixel navigation/control
  heights, explicit automation names, bounded scroll regions and a decorative
  overlay with hit testing disabled. The Windows-only harness checks resource
  parity, all six focusable destinations, compact/large layout rendering and
  the onboarding state without using user content. In CI only, an explicit
  environment opt-in writes exactly three allowlisted PNGs — settings,
  dictionary and onboarding — from hard-coded synthetic state; the workflow
  verifies the exact filenames, runs the artifact privacy scan and uploads the
  evidence separately with seven-day retention.

### W6 licensing and closed-beta boundary

- LD1 tokens are verified locally with the pinned NSec Ed25519 implementation.
  The signature covers the exact decoded payload bytes and is checked before
  JSON, device, email, kind or dates are trusted. The authority is injected;
  this slice does not embed a Windows production or beta authority.
- The committed `Service/fixtures/parity.json` trial, annual and lifetime keys
  pass through the shipping Windows verifier. Edited payloads, another device,
  malformed tokens and an unconfigured authority fail closed. No activation
  endpoint or network transport participates in verification.
- The local entitlement record has exactly five allowlisted fields: install
  time, unlinkable install ID, first successful dictation time, furthest seen
  time and the signed token. It is atomically replaced under local app data;
  transcripts, glossary, history, audio, application names and diagnostics have
  no serialization path through its fixed document.
- The entitlement session persists the first successful result, resists clock
  rollback through the existing policy, accepts a key only after verification,
  restores it after restart, discards a stored token that no longer verifies
  and does not claim acceptance when persistence fails.
- Windows identity is derived from the SMBIOS system UUID returned by the local
  firmware API, normalized, namespaced with a Windows-only product salt, hashed
  with SHA-256 and truncated to 128 bits / 32 lowercase hex. The raw UUID is not
  saved or returned by the product adapter. Missing, zero and all-`ff` UUIDs
  produce an actionable unavailable result instead of a shared or random ID.
- The activation adapter is inert without a compiled HTTPS endpoint and an
  explicit user call. Activation sends exactly `device` and `email`; release
  sends exactly `device` and the already-issued signed key. The concrete client
  disables cookies and automatic redirects, identifies itself only as
  `Witness`, bounds replies to 8 KiB, accepts only an LD1-shaped success and
  keeps device-limit, rejection and temporary-network outcomes distinct.
- Activation never stores a reply until the offline verifier accepts it.
  Device release uses the signed key as proof before deleting it locally; a
  network failure still honors the local removal and returns a distinct warning
  that the remote two-computer slot may remain occupied.
- Product telemetry has no free-form event API: only `trial_started`,
  `activation_requested` and `paywall_shown` can be constructed, with the four
  fixed paywall qualifiers. The fixed wire envelope contains event, optional
  qualifier, app version, coarse `windows-10.0` family and a random install ID.
  Consent is persisted, shown in onboarding and Settings, and read at send time;
  the beta default service performs no network or disk I/O for events.
- The License destination now renders untouched/free-use, activated trial,
  annual, lifetime, expired and update-ineligible states; accepts an explicitly
  requested emailed key or a pasted LD1 key; reports device identity and
  recoverable errors inline; confirms removal; and opens the two bundled beta
  documents. English and German keys remain in parity and use system
  colors/fonts plus native keyboard-accessible controls.
- Entitlement is re-evaluated before microphone capture or target observation.
  A refused hotkey opens License without touching audio; expiry during a phrase
  does not discard that phrase. The first non-empty locally processed result
  starts the three-day window. Licensing operations are serialized so a key,
  clock observation and release cannot race each other.
- A release build can receive only a Base64 32-byte Windows beta public key and
  an exact HTTPS `/v1/activate` URL through assembly metadata at build time.
  The installed app has no authority/URL setting or environment override.
  Ordinary development and CI builds stay unconfigured; the package workflow
  has an explicit opt-in and rejects absent or malformed values. The private
  signing key is never a build input.
- `LEGAL/WINDOWS_BETA_PRIVACY.md` and `LEGAL/WINDOWS_BETA_TERMS.md` are bundled
  internal EN/DE drafts. They enumerate the Windows beta data boundary, keep
  Mac checkout wording out, and visibly retain controller, activation host,
  processor, region and retention placeholders. They are not approved for an
  external beta until those facts are filled and legally reviewed.

### W4 safe insertion boundary

- A recording captures the destination process ID and root top-level HWND before
  the activity overlay is shown. The coordinator rechecks generation, connected
  session, input desktop, foreground root HWND and UIA protected state before
  every automatic content side effect; it never calls `SetForegroundWindow`.
- UI Automation runs on one bounded background STA with a one-item queue and a
  per-observation timeout. Provider failure, timeout, queue pressure, mismatched
  process/window or unavailable properties fail closed as unknown. Password
  fields are refused before clipboard or input work.
- Direct insertion is limited to the known Win32 `Edit` control and uses exact
  selection replacement plus a full-value readback. It never calls generic
  `ValuePattern.SetValue`; an unverified direct write is terminal and cannot be
  followed by a duplicate paste.
- Every Witness clipboard text write sets
  `ExcludeClipboardContentFromMonitorProcessing`,
  `CanIncludeInClipboardHistory=0` and `CanUploadToCloudClipboard=0` before the
  Unicode text. A protection-format or text-write failure clears partial data
  and fails closed instead of exposing an ordinary clipboard fallback.
- The paste path waits a bounded time for only the configured hotkey modifiers,
  writes the protected clipboard only after the final target check and emits one
  `Ctrl+V` sequence with no Enter and no retry. Restore requires exact UIA
  value/selection verification and an unchanged clipboard sequence; otherwise
  the protected dictation text remains available for recovery.
- The test-only owned WPF harness provides keyboard-ordered, automation-labelled
  normal, password and deliberately delayed-paste fields. Fake adapters cover
  locked/unknown/protected targets, target changes, partial input, clipboard
  failures, external clipboard changes and superseded generations without using
  real user content.

## Commands run locally

The .NET SDK was installed only under `/private/tmp/witness-dotnet` for this
development session; no system or repository SDK installation was made.

```text
/private/tmp/witness-dotnet/dotnet restore Windows/Witness.Windows.sln
Result: passed; package lock files generated.

/private/tmp/witness-dotnet/dotnet build Windows/Witness.Windows.sln \
  --configuration Release --no-restore --disable-build-servers -m:1
Result: passed; 0 warnings, 0 errors (cross-targeted on macOS).

/private/tmp/witness-dotnet/dotnet restore \
  Windows/src/Witness.App/Witness.App.csproj --locked-mode \
  -p:PublishProfile=Beta -p:PublishReadyToRun=true
/private/tmp/witness-dotnet/dotnet publish \
  Windows/src/Witness.App/Witness.App.csproj --configuration Release \
  --no-restore -p:PublishProfile=Beta --output Windows/artifacts/publish
Result: passed; self-contained win-x64 ReadyToRun output produced on macOS.

/private/tmp/witness-dotnet/dotnet test \
  Windows/tests/Witness.Core.Tests/Witness.Core.Tests.csproj \
  --configuration Release --no-restore
Result: passed; 86 passed, 0 failed, 0 skipped after the first W2 policy slice.

The current local Windows head builds with 0 warnings and 0 errors and has 148
Core tests. Its desktop-session policy tests, W4/W5 platform/harness tests and W3 native integrations require
the Windows test host and are not reported as passed locally.

Strict local Clang syntax checks pass for the native implementation, public C11
header, ABI test, English inference smoke and multilingual language regression
harness against the exact pinned whisper.cpp v1.9.4 headers. This validates
source compatibility only; MSVC compilation, linking and execution remain CI
gates.

/private/tmp/witness-dotnet/dotnet test \
  Windows/tests/Witness.Update.Tests/Witness.Update.Tests.csproj \
  --configuration Release --no-restore
Result: passed; 6 passed, 0 failed, 0 skipped.

/private/tmp/witness-dotnet/dotnet test \
  Windows/tests/Witness.Core.Tests/Witness.Core.Tests.csproj \
  --configuration Release --no-restore --disable-build-servers -m:1
Result after the W5 settings/session-glossary slice: passed; 148 passed, 0 failed, 0 skipped.

Result after the first W6 offline-license/persistence/identity/network-policy slice: passed; 183 passed,
0 failed, 0 skipped. The managed solution builds with 0 warnings and 0 errors.

Result after the W6 License/configuration/legal slice: passed; 185 Core tests
and 6 update tests, 0 failed or skipped. The managed solution cross-builds on
macOS with 0 warnings and 0 errors. The added WPF/configuration tests compile
but require the Windows test host and are not reported as locally executed.
The required beta-build contract was also checked in both directions: a build
with `WitnessRequireBetaActivation=true` and no values failed before compile;
a build with a synthetic 32-byte public key and exact synthetic HTTPS endpoint
passed. No remote endpoint was contacted.

/private/tmp/witness-dotnet/dotnet build Windows/Witness.Windows.sln \
  --configuration Release --no-restore --disable-build-servers -m:1
Result after the W5 UI/settings slice: passed; 0 warnings, 0 errors. The three
new Windows-only platform tests compile but are not reported as executed on the
macOS host.

ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f) }' \
  .github/workflows/windows-ci.yml .github/workflows/windows-package.yml
Result: passed; both workflow files parse as YAML.
```

The test host required a sandbox exception for its local loopback protocol; no
remote service or production endpoint was contacted. CMake/native compilation
was not run locally because CMake is not installed on the Mac host.

The first self-contained publish attempt correctly exposed `NETSDK1094`: a
normal solution restore does not restore the ReadyToRun pack. Both workflows
now perform a second locked restore with the publish profile and
`PublishReadyToRun=true`; the subsequent local publish passed. Velopack refuses
to cross-package Windows from its macOS host, so the package command itself
remains a Windows workflow gate rather than a locally passed check.

The CI-only `ggml-tiny.en-q5_1.bin` adapter fixture was downloaded once to
`/private/tmp` and independently measured as 32,166,155 bytes with SHA-256
`c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b`.
It is not the product model, is not stored in the repository, and is removed by
CI together with its synthetic WAV before artifact assembly.

The W3 product-model candidate was not downloaded or run on the Mac host. Its
immutable source metadata was independently checked at 574,041,195 bytes and
SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`.
The official eSpeak NG 1.52.0 x64 MSI used only to synthesize CI inputs was
downloaded to `/private/tmp`, measured as 12,765,862 bytes with SHA-256
`7f673c709ea5dd579d3b5ebb98688cc575328a6ab7438d2bc405b88cedaeafb9`,
and is not linked or shipped.
The CI-only Piper `2023.11.14-2` Windows archive and
`uk_UA-ukrainian_tts-medium` voice/config were also downloaded independently
to `/private/tmp`. Their measured sizes and SHA-256 values match the pinned
metadata in `config/language-regression.json`; they are used only to replace an
unrepresentative Ukrainian eSpeak test voice and are never shipped.

## CI and artifacts

- Windows CI run
  [`36325946708`](https://github.com/igskak/localdictation/actions/runs/36325946708)
  passed for source `6fa28a8b023d37e3768bc98b55c068719ca45087`.
- Runner boundary: Windows Server 2025 Datacenter, build 26100, x64. Native
  compilation used the runner-provided Visual Studio 18 Enterprise toolchain,
  MSVC `14.51.36231`. This is not evidence for a physical Windows 11 machine.
- Managed solution build, 76 Core tests, 6 signed-update tests, native ABI test,
  self-contained ReadyToRun publish and privacy filename scan passed. The one
  platform test remains explicitly skipped until W2 supplies real adapters; it
  was not counted as verified behavior.
- The CI-only `tiny.en-q5_1` model loaded with `use_gpu = 0`; the synthetic
  16 kHz mono in-memory PCM produced a non-empty segment with valid timing.
  Neither the model nor WAV was included in the uploaded artifact.
- Uploaded artifact:
  `witness-windows-w0-shell-6fa28a8b023d37e3768bc98b55c068719ca45087`,
  artifact ID `10934211219`, 94,800,049 bytes, retention through 2026-10-04.
  This is a W0 shell build, not an installer or beta.
- Earlier runs documented and resolved three W0 workflow issues: obsolete
  explicit VS 2022 generator (`36324966461`), over-broad CTest scope and split
  DLL output (`36325169813`/`36325463436`), and an over-broad Vulkan filename
  guard (`36325704496`). Expectations were not weakened; the final run executed
  the intended checks.
- The manual package job is intentionally unsigned and must not be distributed
  as a production or signed beta build.
- The first W2 slice passed Windows CI run
  [`36341765309`](https://github.com/igskak/localdictation/actions/runs/36341765309):
  the managed solution built, all 86 Core tests and all 4 Windows adapter tests
  passed, and the existing native/inference/publish/privacy pipeline remained
  green. This hosted run still makes no physical desktop or microphone claim.
- Native sample normalization passed both strict local Clang checks and Windows
  CI run
  [`36341951718`](https://github.com/igskak/localdictation/actions/runs/36341951718).
  The tray/activity lifecycle then kept the full pipeline green in run
  [`36342155220`](https://github.com/igskak/localdictation/actions/runs/36342155220).
  Neither run constitutes a real microphone test.
- WASAPI compiled under MSVC and its creation/ownership contract passed with
  Release assertions in run
  [`36342973047`](https://github.com/igskak/localdictation/actions/runs/36342973047).
  Media Foundation resampling of synthetic 44.1 and 48 kHz mono Float32 input,
  including end-of-stream drain, passed in run
  [`36343401085`](https://github.com/igskak/localdictation/actions/runs/36343401085),
  together with 8 Windows adapter tests and the existing inference/privacy
  gates. No hosted run opened or evaluated a real microphone.
- The bounded capture lifecycle and disconnect preservation tests passed in
  Windows CI run
  [`36343572624`](https://github.com/igskak/localdictation/actions/runs/36343572624).
  Endpoint enumeration, microphone privacy recovery and hotkey-to-capture app
  wiring then passed the complete Windows pipeline in run
  [`36344227926`](https://github.com/igskak/localdictation/actions/runs/36344227926).
  Endpoint identity is the opaque value returned by `IMMDevice::GetId`; no
  unsupported SDK property or friendly-name heuristic is used. The hosted
  runner is still not evidence of a physical microphone.
- Commit `19f871e` adds WTS session notifications and stops an active capture
  on lock, logoff, console disconnect or remote disconnect. It is locally
  committed and the managed solution builds cleanly, but its Windows CI run is
  pending because pushing new code to the external remote was not authorized.
- Local W3 commits through `25a29a6` add the verified model workflow,
  transcription/word/backend contracts and multilingual regression gate. The
  new native path has not run on Windows CI for the same authorization reason;
  these commits are implementation evidence, not a passing Windows claim.
- Local commits `29521c1`, `51216a0`, `6807ab6` and `09e4cdb` connect that W3
  foundation into the app. The coordinator owns only one loaded backend,
  explicitly disposes a failed GPU session before its single CPU creation, and
  applies the same controlled switch to completed-recording language detection.
  The inference pipeline reuses one verified-model session, rejects stale
  generations, transcribes with the selected language code, and clears the
  caller-owned PCM array after success, cancellation or failure. The WPF
  preview requires an explicit profile choice: measured DE/EN/RU/UK automatic
  detection or any single engine language. This has only been cross-built on
  macOS; native loading and UI behavior still require Windows CI/QA.
- Local commit `a117846` adds a test-only benchmark over the same native C ABI.
  It measures verified-model load, completed-recording language detection and
  explicit-language transcription on generated synthetic audio without logging
  transcript text or copying the executable into the product artifact. Commit
  `44e1f91` additionally serializes generation publication with cancellation,
  makes the WPF profile/model handoff thread-visible, and proves a mismatched
  factory backend is disposed rather than leaked.
- Runs `36408649331` and `36410763205` verified the managed build/tests, MSVC
  native build/ABI, real CPU model load and DE/EN/RU synthetic decisions, but
  the eSpeak Ukrainian voice was classified as English. Commit `a01de94`
  carries the capture VAD speech boundary into language detection while keeping
  the full phrase for explicit transcription; 121 Core tests cover the split.
  Run `36412060837` passed 17 Windows platform tests, including session-loss and
  VAD-boundary propagation, then reproduced the Ukrainian eSpeak gap on
  speech-only input. Assertions remained strict; the pinned neural Piper voice
  then replaced only that unrepresentative synthetic Ukrainian fixture.
- Windows CI run
  [`36413673051`](https://github.com/igskak/localdictation/actions/runs/36413673051)
  passed for source `46c570b88b42371c51b7a15884cedf8b77b6cb02`: 121 Core
  tests, 6 update tests, 17 Windows platform tests, native ownership/ABI, the
  RAM-only tiny-model smoke, all 16 leading-noise language decisions, four
  explicit-language transcriptions, the CPU benchmark, self-contained publish,
  artifact privacy scan and upload. Product-model profile scores were
  UK `0.996810`, DE `0.999219`, EN `0.998615`, and RU `0.941023` for the
  expected language; no expected choice was relaxed.
- The hosted Windows Server CPU benchmark used 205,427 samples / 12.839 seconds
  of synthetic English. One iteration measured model load at 454 ms, language
  detection at 39.034 seconds, and explicit transcription at 39.418 seconds.
  These are an honest CPU/two-pass reference, not a Windows 11 laptop minimum
  or GPU claim. Artifact `witness-windows-w0-shell-46c570b88b42371c51b7a15884cedf8b77b6cb02`,
  ID `10966829332`, is 95,056,561 bytes and remains an internal shell build,
  not an installer or distributable beta.
- Windows CI run
  [`36534376223`](https://github.com/igskak/localdictation/actions/runs/36534376223)
  passed for W4 source `9e58b9ace521a67feb1b2fb0580e19afd8d57363`:
  133 Core tests, 6 update tests and 54 Windows platform tests passed together
  with the managed build, MSVC native adapter/ABI, real-model language and
  transcription regressions, CPU benchmark, self-contained publish, artifact
  privacy scan and upload. The platform tests include the owned normal,
  password and delayed-paste WPF harness; they do not substitute for physical
  ordinary-user Word, Chrome or VS Code QA.
- Windows CI run
  [`36583406009`](https://github.com/igskak/localdictation/actions/runs/36583406009)
  passed for W5 source `b35cd55ceb90899988bddcc9640278125e4dc2a0`:
  148 Core tests, 6 update tests and 63 Windows platform tests passed with the
  complete native/model/publish/privacy pipeline. The owned WPF harness rendered
  the settings, dictionary and onboarding states from hard-coded synthetic data;
  the exact three PNG filenames passed the artifact privacy scan and were kept
  separately for seven days. This is hosted-runner layout evidence, not physical
  Windows 11 DPI, high-contrast, keyboard or screen-reader QA.
- Windows CI run
  [`36621031707`](https://github.com/igskak/localdictation/actions/runs/36621031707)
  passed for W6 foundation source
  `0d584111713c5068a4841155b42ed962d328b37f`: 183 Core tests, 6 update tests
  and 85 Windows platform tests passed with the native/model/publish/privacy
  pipeline. This verifies the offline licensing foundation and injected HTTP
  boundary, not the uncommitted License-screen/configuration/legal slice above.

## Known limitations and external gates

- No physical Windows microphone, Windows 11 desktop, standard-user/UIPI,
  Word/browser/Electron insertion, GPU, sleep/wake, Bluetooth/USB device or
  SmartScreen claim has been tested.
- Signing certificate/provider and protected CI credentials are not configured.
- The isolated Windows beta service, its D1 data store, signing identity,
  transactional mail and the protected `WINDOWS_BETA_LICENSE_PUBLIC_KEY` /
  `WINDOWS_BETA_ACTIVATION_ENDPOINT` build values are not provisioned here.
  The code and packaging boundary are ready; no production Mac authority or
  endpoint is reused.
- The bundled Windows beta privacy/terms files remain internal drafts with
  explicit controller/contact/processor/region/retention placeholders and need
  legal review before an external tester receives them.
- A production Windows update/feed host and Windows commercial authority are
  deliberately unconfigured. Mac release/update URLs have not been changed.
- Full third-party license texts still need to be assembled into the external
  beta notices. The current notice file is an engineering inventory.
- The W5 synthetic render harness and focusable navigation checks pass on the
  hosted Windows runner. Physical Windows 11 DPI, high contrast, full keyboard
  traversal and screen-reader behavior remain explicit QA gates.
- The current language-score call prepares and encodes the completed recording
  separately from the later explicit-language transcription. The pinned
  whisper.cpp `whisper_full` API owns PCM → mel → encoder → decoder and exposes
  no supported way to pass the earlier language-detection encoding into that
  high-level call. Witness therefore does not claim encoder reuse or reach into
  whisper.cpp internals; the synthetic benchmark measures the honest two-pass
  cost. A different supported adapter contract would require same-engine output
  parity tests before replacing this path, and no cache may survive a phrase.

## Next step

Run the W6 License/configuration/legal slice in Windows CI. In parallel with the
later W7/W8 work, provision the isolated beta authority/service, set the two
protected package values, verify a synthetic issued key against the packaged
client, and complete/legal-review the named policy placeholders. Physical W5
accessibility, microphone, GPU/performance and ordinary-user Word, Chrome and
VS Code behavior remain pending for external W8 QA.
