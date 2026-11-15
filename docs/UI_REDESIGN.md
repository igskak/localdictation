# Native UI refresh — 15 November 2026

Witness now follows the approved iOS-inspired Mac concept: inset groups,
rounded surfaces, a blue accent, SF Symbols, and system typography. Windows
follow the macOS appearance instead of forcing dark mode.

## Shared components

`WitnessStyle` supplies adaptive surfaces, readable secondary and warning text,
and a separate blue fill for white button labels. `WitnessSettingsForm` and
`WitnessSettingsSection` share the layout across settings, vocabulary,
diagnostics, and licensing. Controls remain native SwiftUI controls, with
their keyboard and accessibility behavior. Language selection and purchase
consent retain checkboxes; preference switches align at the end of each row.

Settings has nine destinations: Dictation, Languages, Text cleanup, Dictionary,
Privacy, License, Updates, Diagnostics, and Audio tuning. License actions from
the menu or paywall request the License destination, including when Settings
has not opened yet. Changing pages cancels shortcut capture.

Onboarding keeps its existing permission, readiness, and microphone-test gates.
It adds a quieter welcome screen, step progress, grouped content, and clearer
primary actions. Language support details are expandable, and search checks
all three language tiers before reporting no matches.

The menu, recording indicator, review, and payment window share the same
appearance. Recording and processing retain distinct labels, including with
Reduce Motion enabled. Review highlights use an adaptive amber surface and
bold emphasis. Audio playback, original text, and copy actions are preserved.

## Copy and localization

Product copy was revised in English, German, Spanish, Italian, and French,
the five existing interface languages. The speech-language catalog and the
verification tiers were not expanded by this change.

The copy uses short, direct instructions and concrete recovery actions. It
removes development-phase descriptions, unnecessary audio-buffer details,
and inaccurate claims about persistence. Diagnostics remain in Diagnostics.
Language names, data placeholders, license dates, and prices keep their
existing sources. The cleanup example is explicitly labeled as English.

Descriptions match the existing insertion policy: with automatic insertion
enabled, text can be inserted before review; review marks remain available
afterwards. A mark asks the user to check a fragment and does not assert that
it is incorrect. No recognition, cleanup, risk, audio-retention, or licensing
policy was changed.

Privacy has its own destination, a summary, an expandable enumeration of
product events, and the existing English privacy-policy link. The transmitted
events, fields, defaults, recipients, and retention behavior are unchanged.

The existing reviewed withdrawal declaration and legal-document language
labels are preserved. The intentional English fallback for the declaration
in Spanish, Italian, and French remains covered by its existing test.

## Verification

- Xcode macOS build and full test suite: **1005 passed, 3 skipped, 0 failed**.
- Settings layout coverage: nine destinations × five interface languages ×
  two appearances at the preferred 900 × 700 window size.
- Contrast checks cover secondary text, warning text, and primary button text
  in light and dark appearances, with a minimum ratio of 4.5:1.
- Localization tests check every destination, catalog completeness, and format
  arguments in German, Spanish, Italian, and French.
- Existing onboarding, permission, shortcut, insertion, review-window,
  local-content, and licensing tests continue to pass.
- Actual SwiftUI screenshots were inspected for settings, privacy, cleanup,
  welcome, language selection, and model preparation.

The UI tests use injected capture, permissions, and stores. Settings previews
construct Sparkle with its update scheduler stopped. They require no live
microphone, model download, or OS permission prompt.

Build output: `build/UIRefresh/Build/Products/Debug/Witness.app`.
Test results: `build/UIRefresh-verified-tests.xcresult`.
Screenshots: `outputs/ui-refresh-2026-11-15/`.
