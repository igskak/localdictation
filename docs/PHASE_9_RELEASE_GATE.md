# Phase 9 release gate

Status: **implemented, not cleared for Clean-by-default**.

The deterministic Flow-Light pipeline and its text-only tests are in the
repository. `AdaptiveCleanupReleaseGate` encodes the thresholds from
`PHASE_9_FLOW_LIGHT.md`; a missing language, missing manual stage, or any single
threshold miss keeps the fresh-install default at **Conservative**. Existing
preferences also continue decoding to Conservative when `cleanupLevel` is
absent.

## Evidence available in this repository

- exact edit-map composition and raw recovery tests;
- protected-span conflict and typed-value ownership tests;
- DE/EN/RU/UK command, correction, repetition, list, percentage, and fallback
  fixtures;
- typed-value render/parse round trips and identifier counterexamples;
- bounded 64/32 UTF-16 context windows;
- secure and stale context refusal;
- context-free fallback equality;
- full Debug test suite and Release build.

These checks establish implementation correctness for the committed fixtures.
They do not substitute for a consented real-speech corpus or a compatibility
run in third-party applications.

## Evidence still required

- private consented real-speech corpus for German, English, Russian, and
  Ukrainian;
- per-language reports for every numeric threshold in the phase plan;
- manual compatibility matrix for the listed native, browser, Electron, code,
  and terminal fields;
- ten-minute repeated-dictation soak;
- blinded work-text comparison with at least 70% preference for Clean;
- latency measurement on the oldest supported Apple Silicon Mac.

Until those results are recorded and all pass together, Clean remains an
explicit Settings choice and `Preferences.default.cleanupLevel` remains
Conservative. No release claim should describe the private/manual gates as
passed.

