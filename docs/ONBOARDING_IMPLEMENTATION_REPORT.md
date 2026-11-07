# Onboarding and single-key implementation — 2026-11-07

Base: commit `d25e72f`, release **0.6.22**, internal build **23**. The live
GitHub appcast was checked and points to the same version and build. Existing
unrelated workspace files were preserved. No release was published.

Implemented:

- Single modifier bindings for left/right/either Command, Option, Control,
  Shift and Fn/Globe, retaining Carbon registration for conventional shortcuts.
  Both recording modes remain available. A listen-only Core Graphics adapter
  requires Input Monitoring, cancels modifier gestures when they become keyboard
  or mouse shortcuts, handles sleep/session changes and checks permission loss.
  The gesture state itself is pure and independently tested.
- Visible shortcut rules, cancellation and confirmation after registration and
  preference saving. Old preference fields continue to decode unchanged.
- Welcome, language selection, microphone, Accessibility, key selection, model
  wait, actual test and completion in the existing setup window. Skip, close,
  back and a persistent menu entry are available.
- Actual model preparation state/progress, a 5–15 minute explanation and request
  to keep setup open. Model readiness advances the wait screen to the test
  without starting the microphone. Existing local notices and opt-in system
  notifications remain available when setup is closed.
- A test destination in the existing dictation coordinator. Test output does not
  enter other apps, clipboard or recent-dictation history, and test cleanup does
  not read another app's text context. Closing cancels pending delivery. Empty
  results and transcription errors remain visible; uncertain output exposes raw
  recognized text.
- Local installation receipt and page checkpoint. A new bundle/executable file
  identity shows setup again with existing choices; skip/close suppresses repeat
  popups for that installation. A one-shot Sparkle relaunch marker preserves
  setup status across the ordinary update path.
- 51 catalog entries with German, Spanish, Italian and French translations;
  local storage/keyboard access documented in `PRIVACY.md`.

Validation: macOS arm64 Xcode build; **120 passing targeted tests, zero failures**
across HotkeyBindingTests, LanguageSetupTests,
DictationCoordinatorTranscriptionTests, RecordingActivationTests,
SettingsViewLayoutTests, CoordinatorPreferencesTests and RecordingStateMachineTests.
New deterministic coverage includes modifier/chord cancellation, single-key
preference persistence, isolated test output, reinstall versus restart/skip,
and rendering all six guided setup pages. Screenshots of key selection and
waiting pages were inspected. No microphone or OS permission dialogs are used
by these tests.

Before a public release, manually exercise physical modifiers and Fn/Globe on
built-in and external keyboards, actual permission granting/revocation, Secure
Input, sleep/wake, and Finder replacement/Sparkle update. Automated adapters do
not establish the hardware or macOS permission behavior. Fn may retain a
system-configured action because the event tap deliberately does not swallow
system events. No downloaded models, recordings or signing material were added.

## Unified shortcut control — 2026-11-07

The onboarding and Settings now share one recorder: Change → press a combination
or press/release a single modifier → automatic save. The separate modifier picker
and Use this key action have been removed. Keyboard-permission controls appear
only when the recorded single key needs that permission. The recording mode
remains immediately below the recorder. Modifier release is used to distinguish
a lone modifier from the beginning of a conventional key combination.

## Release validation — 0.6.23 (build 24)

The complete Xcode suite passed: 986 tests passed, 5 skipped, zero failures.
The translation catalogue check now covers 589 complete entries. The Node
fixture check preserves the entry-point symlink so it also runs from an isolated
release worktree. Service fixture bytes and signing behavior are unchanged.
