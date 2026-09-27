# Windows target instructions

These rules extend the repository root `AGENTS.md` for files under `Windows/`.

## Platform and architecture

- Target x64 Windows 11 build 26100 or newer for the first beta. Windows 10 and Windows ARM64 are not supported targets for this slice.
- Use C#/.NET 10 and WPF for the app, standard Win32/COM/WASAPI/Media Foundation adapters where they fit, and a small C++ C ABI around native audio and whisper.cpp.
- Keep `Witness.Core` free of WPF, Win32, COM, HTTP, file-system, and native-library dependencies so its tests run on macOS and Windows.
- UI state belongs on the WPF Dispatcher. Audio callbacks must stay bounded and must not block on the Dispatcher, resampling, VAD, inference, disk, or network work.
- Run as a normal user. Do not require admin, a service, a driver, `uiAccess`, or Microsoft Store packaging.

## Privacy and content lifetime

- Audio is memory-only in product code. Never create temporary WAV files or persist transcripts, clipboard snapshots, vocabulary, application contents, risk fragments, or audio-derived tensors.
- Never put content-derived values in network requests, URLs, logs, crash exports, CI artifacts, screenshots, or telemetry. Test fixtures must be intentionally synthetic and non-personal.
- Every Witness clipboard write must set the Windows formats that exclude monitor processing, clipboard history, and Cloud Clipboard. If those formats cannot be set, automatic clipboard fallback must fail closed.
- Keep only the latest ten non-empty text results in RAM. History must never retain audio.
- Beta networking is local-only by default. Production-compatible activation and update transports live behind injected interfaces and fixed release configuration.

## Dependencies and verification

- Pin the .NET SDK, NuGet packages, GitHub Actions, Windows runner label, native commits, model artifact, and package hashes. Do not use floating versions.
- Before adding a dependency, document its exact version/commit, source, license, rationale, and transitive notice obligations in `THIRD_PARTY_NOTICES.md` and `IMPLEMENTATION_STATUS.md`.
- Use NSec for Ed25519. Do not implement cryptographic primitives.
- Keep the license authority, beta license authority, Windows update authority, and Mac Sparkle authority separate. Never commit private keys or fixture seeds used to issue distributed beta licenses.
- A Windows build is verified only after an actual Windows CI run. Hosted Windows Server, synthetic audio, fake adapters, and owned UI harnesses are not evidence for physical Windows 11 microphones, GPUs, standard-user application compatibility, or speech accuracy.

## Implementation discipline

- Work in W0-W8 order from `docs/WINDOWS_IMPLEMENTATION_PLAN.md`, keeping `IMPLEMENTATION_STATUS.md` current after each slice.
- Use protocols and injected clocks, file systems, HTTP transports, and OS adapters around side effects.
- Add deterministic tests for state transitions, cancellation generations, buffers/VAD, Unicode offsets, insertion and clipboard races, licensing, privacy allowlists, updater tampering, and data preservation.
- Do not weaken an assertion merely to make a different speech engine pass. Record verified platform gaps explicitly.
- Preserve the Mac client and `Service/`; do not replace either with the stale working-tree versions.
