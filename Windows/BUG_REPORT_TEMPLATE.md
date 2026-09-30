# Witness for Windows beta bug report

Do not attach recordings, free-form dictated text, clipboard contents,
vocabulary, license keys, email addresses, device IDs, serial numbers, crash
dumps or screenshots containing personal/application content. Use only the
fixed synthetic phrase IDs in `QA_CHECKLIST.md`. A screenshot is acceptable
only when every visible value is synthetic and non-personal.

## Build and machine

- Tester ID (coordinator-assigned pseudonym):
- Witness version and build shown in Settings:
- Source revision from `BUILD_INFO.json`:
- Installer SHA-256 verified: yes / no
- Windows edition, version and OS build (`winver`):
- Architecture (`System type`):
- Standard or administrator account (run Witness unelevated):
- PC manufacturer/model; no serial number or asset tag:
- CPU model:
- Installed RAM:
- GPU model(s) and driver version(s):
- Witness backend shown while processing: CPU / accelerated / unknown
- Microphone category: built-in / USB / Bluetooth; omit unique device name
- Display resolution and scale; high contrast: on / off
- UI language and selected speech-language order:
- Windows dictionary availability shown in Diagnostics:

## Reproduction

- Checklist case ID:
- Synthetic phrase ID, if applicable:
- Starting app state:
- Exact actions:
- Expected behavior:
- Actual behavior (describe UI/state; do not paste free-form dictation):
- Reproducibility: every time / intermittent / once
- Did changing the target window, unplugging a device, locking, sleeping or
  pressing another modifier occur? Give only the sequence and timing.

## Impact and recovery

- Severity: blocker / data-or-privacy risk / core function / usability / minor
- Did Witness insert or copy anything after it should have failed closed?
- Did the app recover without restart? If so, how?
- Did settings, model and activation remain after restart/update/reinstall?

## Performance-only fields

- Phrase duration bucket: under 5 s / 5–30 s / 30–120 s / over 120 s
- Cold model load seconds:
- Stop-to-result seconds for each run (numbers only):
- Task Manager Witness peak memory and handle count at warm-up / 15 min / 30 min:
- Do not include recognized text, audio, trace files or content-bearing logs.
