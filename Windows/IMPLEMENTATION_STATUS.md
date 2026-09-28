# Witness for Windows — implementation status

Last updated: 2026-09-28

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
| W3 | **In progress** | Verified local model manager and disclosed download UX; immutable multilingual product-model candidate; cancellable native transcription/token bridge; grapheme word mapping with honest segment-timing fallback; real backend probe and one controlled CPU retry policy; completed-recording language-score bridge with VAD speech boundary; pinned synthetic eSpeak DE/EN/RU plus neural Piper UK leading-noise regression harness; test-only native benchmark; app-level verified-model → completed-audio language decision → explicit-language transcription flow with generation cancellation and immediate audio clearing | Re-run the strict 16 leading-noise decisions and four explicit transcriptions with the representative Ukrainian fixture, then run the CPU benchmark/artifact gates; profile CPU/GPU and decide whether the pinned candidate meets the product bar |
| W4 | Not started | — | UI Automation target/protected checks, modifier wait, clipboard-safe insertion, owned UI harness and race tests |
| W5 | Not started | W0 shell only; it is not a complete user flow | Review/replay integration, six functional Settings sections, onboarding, glossary, bounded visible history, EN/DE resources, synthetic UI screenshots and full hotkey-to-insert path |
| W6 | Not started | Pure entitlement timing/major policy only | LD1 and Service fixture parity, device identity, activation/release-slot adapters, consent/telemetry allowlists, beta test authority and Windows terms/privacy draft |
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

The current local Windows head builds with 0 warnings and 0 errors and has 120
Core tests. Its desktop-session policy tests and W3 native integrations require
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
  speech-only input. Assertions remain strict; the next run substitutes the
  pinned neural Piper voice only for the synthetic Ukrainian fixture.

## Known limitations and external gates

- No physical Windows microphone, Windows 11 desktop, standard-user/UIPI,
  Word/browser/Electron insertion, GPU, sleep/wake, Bluetooth/USB device or
  SmartScreen claim has been tested.
- Signing certificate/provider and protected CI credentials are not configured.
- A production Windows update/feed host and Windows commercial authority are
  deliberately unconfigured. Mac release/update URLs have not been changed.
- Full third-party license texts still need to be assembled into the external
  beta notices. The current notice file is an engineering inventory.
- The WPF shell is a W0 accessibility-aware skeleton, not the finished product
  UI. Windows DPI, high contrast, keyboard navigation and screen reader behavior
  remain CI/physical-QA gates.
- The W3 profile selector is deliberately narrower than the W5 onboarding and
  settings requirement: it offers the verified four-language automatic profile
  or one explicit engine language, but not an arbitrary user-selected mixed
  set. The pipeline already accepts injected mixed profiles; the full selector
  and persistence remain W5 work.
- The current language-score call prepares and encodes the completed recording
  separately from the later explicit-language transcription. The pinned
  whisper.cpp `whisper_full` API owns PCM → mel → encoder → decoder and exposes
  no supported way to pass the earlier language-detection encoding into that
  high-level call. Witness therefore does not claim encoder reuse or reach into
  whisper.cpp internals; the synthetic benchmark measures the honest two-pass
  cost. A different supported adapter contract would require same-engine output
  parity tests before replacing this path, and no cache may survive a phrase.

## Next step

Run the complete Windows pipeline with the pinned Piper Ukrainian fixture.
After the hosted W3 gate is green, profile CPU/GPU on representative Windows 11
hardware and decide whether the pinned model meets the beta product bar before
starting W4 insertion. Physical microphone and ordinary-user desktop behavior
remain explicitly pending until W8 QA.
