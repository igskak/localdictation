# Witness for Windows closed beta — known issues and open gates

Updated: 2026-09-30

## Distribution blockers

- The checked-in packaging workflow creates an unsigned internal Velopack
  installer. Windows code signing, timestamping and real SmartScreen evidence
  are not configured. Do not give that artifact to external testers.
- The Windows beta privacy notice and terms are internal drafts with visible
  controller, contact, activation/update operator, processor, region and
  retention placeholders. They require completion and legal approval.
- The isolated Windows beta activation authority/service and protected build
  values are not provisioned in this repository. Ordinary builds cannot
  activate and never fall back to the Mac production service.
- The real Windows beta update feed, package host, metadata signing credential
  and executable signing credential are not configured. Ordinary builds do not
  contact an update endpoint.

## Current functional limits

- The current package workflow compiles the CPU backend only. Vulkan selection,
  driver compatibility and GPU performance remain pending; a fast GPU does not
  accelerate this internal package.
- The minimum supported OS is Windows 11 x64 build 26100. Windows 10, Windows
  on ARM and 32-bit Windows are outside this beta.
- Language detection and explicit transcription currently perform two complete
  whisper.cpp passes. On the hosted Windows Server CPU, one synthetic 12.839 s
  English sample took about 39 s for detection and 39 s for transcription.
  This is a CI reference, not a laptop requirement or a real-speech result.
- The speech model is 574,041,195 bytes (about 548 MiB), is downloaded only
  after disclosure, and needs an internet connection for initial setup.
- Direct, read-back-verified insertion is limited to a standard Win32 Edit
  control. Other ordinary applications use one protected clipboard paste.
  Elevated targets, password fields, locked desktops, changed target windows,
  unknown protection state and protection timeouts fail closed.
- Windows Spell Checking dictionaries are machine capabilities. When a
  dictionary is absent, only its dependent malformed-word signal is unavailable;
  Witness does not treat every word as wrong.
- Session glossary, recent results and review audio intentionally disappear
  when the app exits. Uninstall intentionally leaves settings, the verified
  model and local entitlement data under `%LOCALAPPDATA%\Witness`.
- Updates are manual: Check, Download and Install/restart are separate user
  actions. A pending package is never auto-applied at launch.

## Evidence still requiring physical Windows 11 hardware

- Built-in, USB and Bluetooth microphones; unplug and default-device changes;
  sleep, wake, lock and session transitions.
- Standard-user insertion in Word, Chrome/Edge, VS Code and desktop messengers;
  clipboard contention and modifier-release races.
- DPI scaling, high contrast, full keyboard traversal and screen-reader output.
- Real EN/DE/RU/UK speech quality, false-warning rate and critical semantic
  errors with native speakers.
- Thirty-minute memory/handle plateau, cold/warm load time and stop-to-result
  p50/p95 on representative 8 GB and 16 GB machines.
- Signed install/update/uninstall/reinstall behavior and SmartScreen reputation.
