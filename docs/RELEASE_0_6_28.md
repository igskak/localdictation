# Witness 0.6.28 (31)

A failed dictation no longer makes the global shortcut appear unresponsive.
The next press retries completed capture-start or transcription failures through
the existing permission and entitlement gates. Parakeet captures shorter than
its 300 ms input minimum show a localized “Recording was too short” notice,
skip inference, release retained audio and leave the next recording usable.
Whisper keeps its existing input behavior.

Automatic onboarding is shown once after installation, reinstallation or an
update, including Sparkle updates. The installation identity uses bundle path,
file numbers, version and build, without the mounted device number. Legacy
receipts migrate without losing progress or the clipboard-only choice. Marking
setup as shown when it opens and disabling window restoration prevents an
unfinished window from returning at the next ordinary launch or Mac restart.
Setup remains available explicitly through the menu.

Validation: 1,245 native Debug tests: 1,234 passed, 11 hardware/corpus/network
opt-in tests skipped, no failures. Regression coverage exercises retry in both
recording modes, revoked microphone access, the 300 ms boundary, legacy receipt
migration, changed mount identifiers, installation/update changes and an
unfinished setup at the next launch. The release uses the existing Developer ID,
notarization/stapling and signed Sparkle feed pipeline. Production artifact
verification is recorded separately after publication.

No new dependency, network request, content transfer or service change.
The updated local onboarding receipt is described in `docs/PRIVACY.md`.
