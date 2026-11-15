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

## Published release — 0.6.25 (build 26)

Published on 15 November 2026 at 20:45 Europe/Prague:
[Witness 0.6.25](https://github.com/igskak/localdictation/releases/tag/v0.6.25).
The release tag identifies source commit
`e42a79cfa7eadcb23b628d2123621bfa86c2f195`.

The distribution was built from a clean, detached checkout with
`Tools/release.sh`. Apple accepted both submissions:

- App: `0cb0b2a3-616d-4256-b770-66925125012f`.
- DMG: `e8579fde-a123-4697-8e58-a5a98d33f4d7`.

Both tickets were stapled and validated. Gatekeeper reported **accepted,
Notarized Developer ID** for the app and DMG. The release commit was tested
again: 1005 passed, 3 skipped, zero failures.

`Witness.dmg` and the signed `appcast.xml` were uploaded together and the
release was made the latest stable version. The existing website download
route needs no deployment: it already uses the latest GitHub release.

Post-publication checks downloaded the DMG through
`https://witnessmac.com/download` with HTTP 200 and fetched the public update
feed. The DMG is 5,857,136 bytes; its SHA-256 is:

```text
15bbb1a9531f5fc1a5df942e20f5c28cd26281aa2d462a0728cbb7857e57cade
```

The public DMG and feed passed Ed25519 verification with the public key
extracted from the preceding published, signed 0.6.24 app. The key is unchanged,
the build increases from 25 to 26, the feed points to the versioned 0.6.25 asset,
and the macOS minimum remains 14.4. The downloaded DMG also passed stapler and
Gatekeeper checks. This verifies the update artifacts and trust chain; an
interactive Sparkle installation and a first run on a separate clean Mac were
not performed in this session.

## Published release — 0.6.26 (build 27)

Published on 15 November 2026 at 22:29 Europe/Prague:
[Witness 0.6.26](https://github.com/igskak/localdictation/releases/tag/v0.6.26).
The release tag identifies source commit
`0b3d38b0491050f109cb80b749be1b7a9e84f621`.

This release checks the current macOS notification authorization before
requesting it. When the system permission was previously denied, Witness shows
an **Allow Notifications / Don’t Allow** choice; Allow opens Notification
settings. Existing grants start model-ready monitoring without another request.
The explanatory copy is localized in English, German, Spanish, Italian, and
French.

The clean release checkout was archived, signed, notarized, and packaged with
`Tools/release.sh`. Apple accepted both submissions:

- App: `7918bab2-7c67-4adc-bb8f-53209e4ce457`.
- DMG: `23629354-c1da-4191-883e-2c69047a7198`.

Both tickets were stapled and validated. Gatekeeper reported **accepted,
Notarized Developer ID** for the app and DMG. The release commit passed 1005
tests; 3 were skipped and none failed.

The signed Sparkle feed and `Witness.dmg` were uploaded together and the release
was made the latest stable version. The website download route needed no
deployment. Fetching `https://witnessmac.com/download` returned HTTP 200 and a
DMG with the same SHA-256 as the published asset. The public feed also returned
HTTP 200. The DMG is 5,859,052 bytes; its SHA-256 is:

```text
2a1826d92517b6aae61a0741c179ac8335d6616ed36c0f68ea6b68ae6dd0e472
```

The appcast SHA-256 is
`a84f42b839503b573786d7b47261fc5276c102bdd4330d7fe7e6d4487a45010e`. Both
public artifacts match the signed local files. The DMG and appcast signatures
passed Ed25519 verification with the public key from the preceding published
0.6.25 app. The build increases from 26 to 27, the feed points to the versioned
0.6.26 asset, and the macOS minimum remains 14.4. An interactive Sparkle update
and a first run on a separate clean Mac were not performed in this session.
