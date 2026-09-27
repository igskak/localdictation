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
| W0 | **In progress** | Pinned solution/toolchain/dependencies; Core and WPF shell; Windows CI and manual packaging workflows; C ABI for whisper.cpp; signed-manifest/verified-package spike; privacy endpoint inventory; build metadata; baseline hashes; CI-only synthetic CPU inference smoke with a hash-pinned fixture model | Run Windows CI; compile and exercise native code on Windows; obtain a successful actual RAM-only PCM-to-whisper CPU smoke with text/timing assertions and no Vulkan dependency; retain CI evidence/artifact |
| W1 | **In progress** | Recording state machine and cancellation generation; bounded PCM buffer and energy VAD; complete engine language catalog, selection/pin/continuity policy; final-recording language timing guard; Unicode boundary map; conservative cleanup/edit map; all risk signals and measured prose bounds; review thresholds/history rules; entitlement/lifetime pure policy | Pass the same Core suite on Windows CI; audit any remaining release fixtures before marking the phase complete |
| W2 | Not started | — | Tray, single instance, hotkeys, startup, WASAPI/resampling, device selection/fallback, permissions/interruption, activity UI and Windows adapter tests |
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
Result: passed; 76 passed, 0 failed, 0 skipped.

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
  [`36324966461`](https://github.com/igskak/localdictation/actions/runs/36324966461)
  executed for source `31a8bfc89e296e254614e45e064c2bdfa3e3cd5d`.
  Managed restore/build, Core tests, signed-update tests and the Windows
  platform test step passed. The run then failed during native configure
  because the pinned `windows-2025` image no longer contained the explicitly
  requested `Visual Studio 17 2022` generator. The workflows now let CMake
  choose the compiler installed in the pinned runner image; a successful rerun
  is still required.
- There is no validated Windows installer, successful CI build artifact or
  Windows native inference result yet.
- The manual package job is intentionally unsigned and must not be distributed
  as a production or signed beta build.

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

Put only the isolated Windows/root-scope files on a clean branch based on the
0.6.8 release commit and run `windows-ci.yml`. Fix the workflow/native adapter
until the actual Windows CPU inference smoke succeeds. W0 cannot be marked
complete until that run and its artifact evidence exist.
