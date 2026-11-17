# Witness 0.6.27 (30)

The model picker, optional final onboarding step and compact menu bar now share
an adaptive blue/slate native design. Glass is restricted to navigation controls
on macOS 26+, with opaque, readable fallbacks on macOS 14.4+ and when Reduce
Transparency is enabled. No new dependency is introduced by the design.

The menu separates Dictation and Notetaker. A compact status row reads the
current saved and registered shortcut and recording activation mode. Failed
shortcut proposals cannot replace the working instruction. Active recording,
permission/license/security notices and transcript review remain above the tabs.
History is collapsed; Setup and practice and Quit live under More actions.
The panel measures its content and scrolls only when it exceeds the screen.

Notetaker is available as a public demo. A Demo badge and plain-language notice
in both the menu and recording window explain that speaker separation is still
improving. This release does not claim an improvement in diarization accuracy.
The shared engine selection serves both features; the separately bundled
Nemotron model only produces speaker labels, entirely locally.

Model selection downloads without replacing the running engine. Completed
choices wait for a restart and local preparation, with progress, notifications,
cancel/retry and protection of active models. Restart is blocked while either
feature is busy. Initial language and permission gates are preserved.

Confirmed Sparkle installations also defer relaunch until both features are idle;
a cancelled update cannot resume later.

Validation: 1,232 Debug tests, including deterministic shortcut/mode integration,
model selection/download/restart tests and light/dark native window fixtures.
Eleven hardware, corpus or network opt-in tests are skipped by default.
`Tools/release.sh` verifies the speaker model, signs the exported bundle with
Developer ID and audio entitlements, notarizes/staples the app and DMG, and
signs the Sparkle feed. Only the final verified DMG and appcast are published.

The website release updates both DE/EN terms, privacy and model notices, with
model sources/sizes, metadata and retention disclosures, local meeting-note
storage and the demo limitation. Content is never uploaded.
