# Speech model selection — next release

Shipping in Witness 0.6.27 (30), following review of the model-selection,
onboarding and compact menu-bar previews. Model selection is available in
ordinary Release builds. Notetaker is enabled as a clearly labelled public demo;
speaker separation remains in development and can misattribute speakers.

## User flow

Settings → Speech model explains speed, recognition, languages and approximate
disk sizes. It offers Whisper large-v3 turbo (1.64 GB), full Whisper large-v3
(3.20 GB), Parakeet Ultra (632 MB) and Parakeet TDT v3 (483 MB). Unsupported
language profiles disable the incompatible choices. The optional seventh/final
onboarding page reuses these controls and can be skipped without changing the
active model. Restart from that page completes onboarding before quitting.

Download and select requests notification authorization when needed, fetches
only model assets and shows byte-based progress. The current speech engine
keeps serving both entry points. Closing Settings or finishing onboarding does
not cancel the download. Cancel leaves completed files available for retry.
Failures leave the working choice intact. Download completion persists a separate
pending choice and sends a local notification. Already installed models need no
network access and go straight to the pending/restart state.

A restart, including an ordinary quit/reopen, applies only a completely installed
choice compatible with the saved language profile. A local preparation marker
causes the next launch to display a non-modal popup until the engine reports
ready. The popup has an indeterminate indicator, not a fabricated percentage.
It can be closed while preparation continues. Readiness clears the marker,
closes the popup and sends a ready notification once. Failure retains the marker
and offers retry or model settings. A long Parakeet load now reports compilation,
using the same 20-second distinction as the existing Whisper adapter, so it does
not invite dictation into a prolonged first compilation.

Restart is disabled while dictation/capture/insertion or a meeting is busy.
Active, downloading and pending models cannot be removed. Removing an inactive
model moves its folder to Trash. The UI explains that macOS compilation caches
use additional space. Closing the app stops downloads; already completed model
files are reused on retry.

## Boundaries

`SpeechModelSelection` is a MainActor presentation/lifecycle service with
injected storage, downloader, notifications and defaults. Download generations
ignore late progress and completion after cancellation. A separate actor fetches
files without loading Core ML; FluidAudio's `AsrModels.download` is deliberately
not used because it also loads models. A single selected speech model is still
constructed by the existing composition root and inference queues.

Asset requests use an ephemeral URLSession without cookies or credentials.
Repositories and revisions are fixed in the model catalog. File paths are
validated, large-file SHA-256 values and listed byte sizes are checked, complete
files are replaced atomically, and disk capacity is checked before transfer.
Metadata and weights are the only network payloads; no content is uploaded.
No dependency or product event is added. See `PRIVACY.md` for local retention
and request disclosure and the bundled `SpeechModels-NOTICES.txt` for licenses.
The matching website terms, privacy and third-party notices disclose model
selection, static asset delivery, local retention and the Notetaker demo in
German and English.

The active model ID, downloaded pending choice and preparation marker are
separate local settings. Test-host startup never consumes real pending choices.
The model preparation controller and notification service are not started by
tests unless explicitly instantiated with isolated fixtures.

## Validation

- Debug suite: 1223 tests, 10 opt-in/corpus tests skipped, zero failures.
- Controlled tests cover progress, cancellation, stale completion, retry,
  denied notifications, missing pending files, unsupported languages, protected
  deletion, restart application and one-shot preparation notifications.
- Download tests cover incomplete/path-traversing/duplicate manifests, corrupt
  files, completed-file reuse, and insufficient disk space.
- Opt-in HTTP smoke verified all four pinned manifests and fetched only their
  small configuration JSON files through the production URLSession transport.
  No real speech, model inference or large model transfer was needed.
- Native SwiftUI snapshots cover idle, downloading, failure, ready-to-restart,
  the optional onboarding step, preparation, light/dark and existing interface
  languages. Source strings are translated in DE/ES/IT/FR.

Re-run standard tests with `xcodebuild test`. To also run the small public
artifact transfer check, set `TEST_RUNNER_WITNESS_MODEL_DOWNLOAD_HTTP_SMOKE=1`.
Snapshots from the fixture test are exported to `/tmp/witness-model-selection-preview`.

- The public Release enables the demo without dogfood flags. Its diarization
  model is bundled from a pinned, hash-verified artifact before Developer ID
  signing and notarization.
