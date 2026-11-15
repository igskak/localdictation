# Onboarding audit — 15 November 2026

Scope: source and permission adapters at released commit 57fc8ff (0.6.23,
build 24). Public appcast checked: still 0.6.23 / 24. The locally installed test build is
excluded from this work at the user’s request. No native permissions were reset
or granted, and no microphone or user content was read during this audit.

## Expected permission behavior

- Microphone: requested by the explicit Allow microphone action; needed to record.
- Accessibility: needed for automatic insertion into other apps; an existing
  grant requires no fresh prompt. macOS grants this in System Settings.
- Input Monitoring: needed by the optional single-modifier adapter; conventional
  Carbon combinations do not need it. The current request appears only after
  a single-key assignment fails for missing keyboard access.
- Notifications: optional, requested only by Notify me when ready during model
  preparation. A ready/cached model can bypass this screen entirely.
- Local WhisperKit recognition does not use Apple's Speech permission flow.
- Login items are a separate explicit setting, not a microphone-like permission.

## Confirmed gaps

1. **Accessibility action never requests trust in the new guide.**
   GuidedSetupView page 1 calls openAccessibilitySettings(), which only opens
   the pane. The existing requestAccessibilityTrust() ->
   AXIsProcessTrustedWithOptions(prompt: true) path is not used there.
   A clean installation may need to be added to the list manually. The action
   should request trust after the user's click and provide a direct Settings
   fallback; existing grants should remain untouched.

2. **A successful test does not establish automatic-insertion readiness.**
   Page 1 always permits Next; enterTest() checks microphone, binding and model
   but deliberately not Accessibility. Test output stays inside the onboarding
   window. The final screen has no explicit clipboard-only status. Continuing
   without Accessibility should be a clear choice, and completion should show
   the remaining limitation rather than implying that external insertion was
   tested. Do not write test content into another app to check this silently.

3. **A refused single-key assignment can be passed over using the old binding.**
   HotkeyRecorderRow keeps pendingBinding in local view state and restores the
   old working shortcut on permission failure. Page 2 sees only that old
   registered binding, so Next is enabled. Navigation should distinguish the
   requested choice from the active fallback and offer an explicit choice to
   keep the previous shortcut or finish enabling the new one.

4. **Minimize instruction is inconsistent with the actual window.**
   LanguageSetupWindowController uses [.titled, .closable], without
   .miniaturizable, while the waiting screen invites minimizing the window.
   Enable native minimization; preserve the ready notification/follow-up when
   minimized, without capturing keyboard focus automatically.

5. **Some model notices still assume hold-to-talk.**
   SpeechModelNotice.message says Hold in waiting and ready states regardless
   of RecordingActivation. The new guide and system notification are already
   dynamic/generic, but the existing floating notice can contradict toggle
   mode. Use the actual activation mode throughout; also avoid promising
   direct cursor insertion where only clipboard fallback is available.

## Recommended acceptance checks

Use injected permission services for automated checks: fresh installation with
all access missing, pre-authorized reinstall, Accessibility granted/denied,
explicit clipboard-only continuation, pending single-key permission with an old
valid shortcut, both recording modes, cached/downloading/failed model, minimized
and closed setup, and permission changes while the test page is open.

Perform a separate native check using the installed release identity. Existing
render tests and pure gesture tests do not exercise a real macOS trust prompt
or prove that a fresh app appears in System Settings. Do not reset the user's
existing privacy permissions as part of a routine audit.

At audit start, this document changed no app behavior and no new release had been published.


## Fixes applied in the working copy

All five findings above are addressed:

- The explicit Accessibility action invokes the existing trust request and
  opens the correct settings pane when access is still missing. Existing grants
  are respected and never requested again automatically.
- Next is disabled on the insertion step until access is granted or the user
  explicitly chooses copy/paste. That choice is retained locally in the setup
  receipt; old receipts decode safely. Completion separately reports whether
  automatic insertion is enabled and does not claim that an external insertion
  was tested. A user's existing preference to disable insertion is preserved.
- Failed shortcut selection stays in coordinator state, survives a disappearing
  recorder, and blocks Next while the old working binding remains registered.
  Retrying or explicitly keeping the current shortcut resolves the choice.
- Native minimization is enabled. A minimized or inactive window never arms the
  test on model readiness. Focus changes pause test routing and cancel pending
  capture/transcription; an already completed test is kept in memory until the
  user leaves the test step. That cached result is separate from normal results.
- All visible model notices use the selected activation mode and current key.
  Ready notices only promise cursor insertion when it is actually enabled;
  otherwise they point to copying the result from Witness.

Regression checks use injected permission and audio services, not OS dialogs
or a microphone. They cover explicit clipboard continuation, new and pre-granted
Accessibility access, pending-key failure and retry, preserving a working old
shortcut, state recovery on re-registration, receipt migration, window style,
model readiness while inactive, permission changes on the test page, preserving
completed test data while paused, and both recording modes in all model phases.

Final Xcode validation: 1000 tests passed, 3 skipped, zero failures.
All new messages include German, Spanish, Italian and French translations
(608 complete catalogue entries). New permission and clipboard-only completion
screens were rendered and visually inspected. No new release was published.
