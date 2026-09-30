# Witness for Windows closed beta

This is an invitation-only Windows 11 x64 beta for testing local dictation. It
is not a public or paid Windows release and does not promise that an existing
Mac license covers Windows.

## Included

- Memory-only microphone capture with a ten-minute hard bound, local VAD and
  local whisper.cpp recognition using the pinned multilingual model.
- Explicit language profiles covering every language known to the engine.
  English, German, Russian and Ukrainian are the measured verification tier;
  language-specific cleanup and warning rules stay off for other languages.
- `Ctrl+Shift+Space` hold or toggle operation, configurable in Settings.
- Conservative cleanup, visible uncertainty review, bounded in-memory replay
  for a flagged fragment and the latest ten non-empty results in RAM.
- Protected insertion into a known standard Edit control and a fail-closed
  protected clipboard fallback for other ordinary applications.
- English and German UI, first-run language selection, microphone selection,
  voice-boundary controls and a session-only glossary.
- Offline license verification after activation and a manual, separately
  signed update-manifest path when the beta build is explicitly configured for
  those isolated services.

## Privacy boundary

Audio is not written to disk. Dictated text, in-memory history, session
vocabulary, clipboard contents, application contents and risk fragments are
not sent by Witness. Model download, explicitly requested activation, optional
product events and manually requested update checks are the only designed
network paths and are subject to the bundled beta notice and build
configuration.

## Build trust

The current repository workflow produces an **unsigned internal package**.
That package is not approved for external distribution. A tester-facing build
must identify its source revision and checksum, contain the approved isolated
beta configuration and legal text, and pass Windows code signing before the
coordinator sends it to external testers.

See `KNOWN_ISSUES.md` before testing and use `QA_CHECKLIST.md` for results.
