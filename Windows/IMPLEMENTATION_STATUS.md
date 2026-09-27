# Witness for Windows — implementation status

Last updated: 2026-09-27

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
| W2 | **In progress** | WPF tray lifecycle, named single-instance lease and non-activating activity badge; pure hold/toggle gesture and audio-device/interruption policies; transactional Win32 hotkey registration with release hook; current-user startup opt-in; bounded native PCM16/24/32/Float32 stereo-to-mono conversion contract and deterministic adapter tests | Hotkey/capture app wiring, WASAPI capture and 16 kHz resampling, microphone authorization/interruption adapter, synthetic UI harness and physical hardware QA |
| W3 | Not started | Native inference contract exists only as a W0 spike | Model manager, pinned product model/hash, offline reuse, cancellation, word mapping, CPU retry/Vulkan capability, leading-silence language corpus and synthetic DE/EN/RU/UK CI smoke |
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
- Native sample normalization was also compiled with strict Clang warnings and
  its deterministic contract test passed locally. It does not yet constitute
  the required WASAPI/Media Foundation capture and 16 kHz resampling path.

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

## Next step

Implement W2 in the same isolated branch: lifecycle/tray/single-instance,
hold/toggle hotkeys with conflict recovery, startup opt-in, WASAPI capture and
conversion, device selection/fallback, permission/interruption outcomes and an
owned Windows adapter harness. Keep microphone and ordinary-user behavior
explicitly pending until physical QA.
