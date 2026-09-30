# Witness for Windows closed-beta tester guide

This guide is for an explicitly approved, code-signed closed-beta build. The
repository's default package is unsigned and internal-only. Stop if your kit's
`BUILD_INFO.json` says `unsigned-internal`, if the installer checksum differs,
or if the coordinator did not provide the build directly.

## Before installing

Use Windows 11 x64 build 26100 or newer and a normal, non-elevated user account.
You do not need Visual Studio, Python, a .NET SDK or a separate speech engine.
Keep the supplied kit together; it contains the checksum, notices, release
notes, known issues, checklist and report template.

Verify the installer from PowerShell in the kit directory:

```powershell
Get-ChildItem .\Witness-Windows-Beta-*-x64-Setup.exe | Get-FileHash -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

The two hashes for the installer must match exactly. Also confirm that the
version, build and source revision in `BUILD_INFO.json` match the coordinator's
message. Do not upload the installer or beta key to another service.

## First run

1. Install and launch Witness. Record whether Windows shows a verified signer
   and any SmartScreen prompt; do not bypass an unexpected unsigned warning.
2. Read the bundled beta terms and privacy notice. Stop if they still contain
   bracketed placeholders.
3. Select every language you actually plan to exercise. The first selected
   language is the deterministic fallback for ambiguous phrases.
4. Keep product-event sharing off unless the test assignment explicitly asks
   you to verify that consent control. It is never required for dictation.
5. Start the disclosed model download. Witness should report verification and
   reuse the model offline after the first successful setup.
6. Activate only with the beta credential supplied for this machine. Never put
   the key, email or device identifier in a report.
7. Confirm `Ctrl+Shift+Space` and the selected hold/toggle behavior in an empty
   Notepad document before testing other applications.

## Running the checklist

Use the exact synthetic phrases in `QA_CHECKLIST.md`; do not use messages,
documents, names, addresses or other personal material. Compare recognition on
the machine. In reports, identify the phrase by ID and submit counts or the
changed word positions. Do not attach audio or paste free-form transcripts.

Run CPU cases on every machine. Run accelerated-backend cases only when the
assigned build says it contains that backend and Witness actually reports it.
Never infer GPU use from the presence of a GPU. Record the backend displayed by
Witness.

For latency, use a local stopwatch and record numbers only. For the soak, use
Task Manager to record Witness memory and handles after warm-up, at 15 minutes
and at 30 minutes. These observations remain manual and are not uploaded by the
app.

## Update sequence

The coordinator supplies the baseline version first. Finish the baseline
install and preservation cases before the successor is published to the same
isolated beta channel. Then use Settings → General → Check for updates,
review the notes, explicitly download, and explicitly install/restart. Witness
must not check or apply an update merely because it started.

After the successor starts, verify that languages, microphone selection,
shortcut mode, entitlement and model remain. Session glossary, recent history
and review audio must be empty because they are intentionally memory-only.

## Removing the beta

Uninstalling removes application binaries but intentionally leaves settings,
the verified model and local entitlement record under `%LOCALAPPDATA%\Witness`.
It does not contact the activation service or release a device slot. Use the
explicit License removal action before uninstall only when the coordinator asks
you to test remote slot release.

If complete local-data removal is needed after the test, close Witness and ask
the coordinator for the current cleanup instruction. Do not delete shared or
broad `%LOCALAPPDATA%` directories.

## Reporting safely

Start from `BUG_REPORT_TEMPLATE.md`. A useful report has the exact build,
machine/OS/backend fields and checklist ID but no user content. Treat any
unexpected content persistence, network request, unprotected clipboard write,
password-field action or insertion into a changed window as a high-priority
privacy/safety defect and stop that scenario.
