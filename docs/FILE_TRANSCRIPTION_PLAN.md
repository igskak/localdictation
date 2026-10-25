# File transcription — implementation plan

Status: F0-F4 built 2026-10-25 on `claude/file-transcription-stages-11a7ec`.
Open before a release: the list under "F4 result". Not merged into `main`.

This document is the implementation
contract for transcribing an existing audio or video file into text with
Witness. It builds on the Notetaker work on
`claude/notetaker-baseline-update-0a65bb` (14 commits on top of `main` at
`f880a54`, not merged into `main` as of this date) and does not change that
branch's release gates by itself.

Market context and the paid-search test it serves are in
`../../РЕСЕРЧ_транскрибация-DE_Transparency-и-план-группы_20261025.md`; the
German landing page is planned in `docs/TRANSCRIPTION_LANDING.md`.

## Product result

1. The user chooses `Transcribe audio file…` in the Witness menu, or drops a
   file on the Witness window, and picks one m4a, mp3, wav, aiff, caf, mp4 or
   mov file.
2. Witness decodes it locally, shows progress, elapsed time and an estimate of
   the time left, and can be cancelled at any point without leaving a partial
   file behind.
3. The result opens as a note in the existing meeting library: readable turns,
   timestamps, uncertain recognition marked, numbered speakers when diarization
   is available, the raw recognition behind every row.
4. The user renames speakers, reassigns a row, edits, and exports TXT,
   Markdown, DOCX, SRT, or a timestamped transcript for qualitative-analysis
   tools.

Nothing about the file leaves the Mac. The file is read where it is; Witness
does not copy it, keep its audio, or keep speaker embeddings. Only the
transcript is stored, exactly as for a meeting note.

## Why on the Notetaker branch rather than from scratch

A file is a single, already-complete audio source. Nearly everything the
meeting path needed for a long, multi-speaker recording applies unchanged:

| Need for a file | Already on the Notetaker branch |
| --- | --- |
| Cut hours of audio into recognisable pieces without repeating words | `MeetingWindowBuilder`: non-overlapping windows that end in a pause, 8–20 s |
| Skip silence without losing the timeline | `MeetingSpeechDetector`, timeline-preserving skip in `LongFormTranscriber` |
| Bounded queue in front of WhisperKit, cancellation, metrics | `LongFormTranscriber`, `LongFormMetrics` |
| Readable turns, raw text retained, low-confidence rows labelled | `MeetingTranscriptAssembler` |
| Numbered speakers | `BundledNemotronSpeakerDiarizer` (FluidAudio 0.17.7 + Nemotron 3 Core ML), `SpeakerAttributionAligner`, `SpeakerAttributedRowBuilder` |
| Rename / reassign / restore speakers | `MeetingTranscriptRecord.assigningSpeaker`, library window |
| Local storage, search, delete, TXT/Markdown export | `FileMeetingStore`, `MeetingLibraryWindow` |
| Fewer hallucinated retries on weak audio | `WhisperKitTranscriptionService.maximumTemperatureFallbacks = 1` |

The new code is the file reader, an offline session that feeds these parts
faster than real time, the entry points and progress UI, three export
formats, and the release flag. Diarization is easier on a file than in a
meeting: there is one source, no echo, no clock drift, and the whole recording
is available, so speakers do not have to be decided before later audio exists.

## Decisions

- **Builds on the Notetaker branch.** Step F0 below merges it into `main` with
  every Notetaker feature still disabled; file transcription then ships behind
  its own flag. Meeting capture (process taps, system-audio permission,
  meeting detection) stays dogfood-only and is not a prerequisite.
- **The file is the `system` source.** Its chunks use
  `MeetingAudioSource.system`, so the diarizer, which only labels remote
  audio, treats every voice in the file as `Speaker 1…8`. There is no `You`.
  The store gets a new `MeetingPlatform.file` so library, exports and
  telemetry can tell file notes from meetings.
- **No audio is persisted.** Decoded PCM lives in bounded memory as in the
  meeting path. Replaying a fragment re-reads it from the user's original
  file, by path, and fails visibly if the file has moved.
- **Language** comes from the user's Witness profile, as in meetings. A
  single-language profile pins the decode; a mixed profile decides per window
  through `LanguageDecision`.
- **Same entitlement as dictation.** A file transcription is a use of the
  product under the existing rules in `EntitlementPolicy`; it starts the
  ungated window and the trial exactly as a first dictation does. No separate
  price for the paid-search test.

## Architecture

```text
NSOpenPanel / drop
  -> AudioFileSource            (AVAssetReader → 16 kHz mono Float32,
                                 1-second MeetingAudioChunk, contiguous frames)
  -> FileTranscriptionSession   (actor; offline, backpressured)
       -> MeetingWindowBuilder(.system, file-tuned sizes)
       -> LongFormTranscriber   (existing; WhisperKit)
       -> StreamingSpeakerDiarizationService.ingest(chunk)   (when available)
       -> SpeakerAttributionAligner + SpeakerAttributedRowBuilder
       -> MeetingTranscriptAssembler
  -> FileMeetingStore           (MeetingPlatform.file, transcript only)
  -> MeetingLibraryWindow       (result, edit, speakers, export)
```

### `AudioFileSource`

- `AVAssetReader` with an `AVAssetReaderAudioMixOutput` set to linear PCM
  16 kHz mono Float32. It handles audio files and the audio track of mp4/mov
  without a third-party decoder.
- Emits `MeetingAudioChunk` of 16 000 frames, `startFrame` contiguous from 0,
  `isFinal` on the last one. No host time: a file has no gaps.
- Reports total duration up front for progress; fails with a named error for
  no audio track, DRM-protected asset, unreadable file, or zero-length audio.
- Behind a protocol so session tests feed synthetic chunks without a file.

### `FileTranscriptionSession`

Modelled on `DebugMeetingSession`, but offline:

- **Backpressure, not loss.** The live path records a lost interval when
  `LongFormTranscriber.enqueue` throws `backlogFull`. A file reader instead
  waits for `drainOne()` and retries. No interval of a file is ever dropped.
- **Window sizes are a measurement input.** Start with the live defaults
  (min 8 s, max 20 s, 300 ms pause). Benchmark 15/28 s as well: a file does not
  need a first result after eight seconds, and longer windows give Whisper more
  context and fewer decode calls. Every window must stay inside Whisper's 30 s.
- **Diarization** consumes the same chunks the windows are built from.
  `prepare()` failure or an inference error falls back to unlabelled rows and
  says so in the result, as the meeting path does.
- **Progress** = frames recognised / total frames; time left from measured
  inference time per audio second. Cancellation calls
  `LongFormTranscriber.cancel()`, discards the in-progress note, and writes
  nothing.
- **Risk evidence.** Rows carry the `riskEvidence` the record type already has,
  so uncertain numbers, names and low-confidence words are marked as in
  dictation. A file transcript never hides an uncertain passage behind a clean
  sentence.
- Inference shares the one WhisperKit engine with dictation. While a file is
  running, a dictation press is answered with "Witness is transcribing a file"
  rather than queued behind an hour of audio. A meeting cannot start while a
  file runs, and the reverse.

### Exports

`MeetingExportFormat` gains three cases; TXT and Markdown exist.

| Format | Content | Notes |
| --- | --- | --- |
| DOCX | Speaker, timestamp, paragraph per turn | `NSAttributedString` with `.officeOpenXML`; no dependency |
| SRT | Cue per row, `hh:mm:ss,mmm` | For video files |
| Timestamped text for QDA | Turn text with `#hh:mm:ss-d#` stamps | Format to verify against MAXQDA and f4 import documentation before it is named in the UI or on the site |

Every export uses the current speaker names from the manifest and the edited
text, never the raw recognition unless the user exports raw explicitly.

## Slices

### F0 — land the Notetaker foundation on `main`, disabled

- Merge `claude/notetaker-baseline-update-0a65bb` into `main` after its own
  test suite and a Release build without `NOTETAKER_DOGFOOD` pass.
- Confirm the ordinary Release composition root still constructs no Notetaker
  UI, permission or capture dependency, and that the FluidAudio package is
  linked but idle.
- Gate: existing dictation regression tests pass; the Release app's menu is
  unchanged.

**F0 result (2026-10-25).** `claude/notetaker-baseline-update-0a65bb` merged
without conflicts into the file-transcription branch, which is `main` at
`f880a54` plus that merge; fast-forwarding `main` itself is the owner's step.
Checked in a clean checkout of the merge commit:

- Release build without `NOTETAKER_DOGFOOD` and without `NOTETAKER_DIARIZATION`:
  `BUILD SUCCEEDED`.
- Full test suite: 1070 cases, 1069 pass. The one failure is
  `ActivationServiceParityTests.testTheCommittedFixtureIsWhatTheServiceProducesToday`,
  which launches Node from inside the test host. Running the same generator by
  hand (`node Service/tools/parity-fixture.mjs`) produces a file byte-identical
  to the committed fixture, so the fixture is current and the failure is the
  test host's process environment, not the merge.
- `NotetakerAvailability.liveDefault` is `.disabled` without the flag, so
  `NotetakerCompositionRoot` returns `UnavailableNotetakerFacade` and
  `MenuBarView` shows none of the Notetaker items. FluidAudio is linked and
  `ProductionDiarizationFactory.make()` returns the unavailable diarizer
  without `NOTETAKER_DIARIZATION`, so no model loads.
- One thing the merge changes for the ordinary build: `Info.plist` gains
  `NSAudioCaptureUsageDescription`. It is a string only; macOS asks for the
  permission when a tap is created, which nothing in Release does.

### F1 — offline engine harness

- `AudioFileSource`, `FileTranscriptionSession`, `MeetingPlatform.file`.
- Debug launch argument `--transcribe-file <path>` that prints progress and
  metrics and writes the note to the store. No product UI yet.
- Deterministic tests: chunk continuity, final chunk, backpressure without
  loss, cancellation leaving no note, unsupported-file errors, window sizes.
- Benchmark on the minimum supported Apple Silicon Mac, consented recordings,
  DE and EN: real-time factor, peak memory, and word error rate against a
  hand-made reference for 2 × 10 minutes per language.
- Gate: a 60-minute file completes with bounded memory and no lost interval;
  RTF and WER recorded in this document. If a 60-minute file takes longer than
  the recording itself, stop and reconsider window sizes or model before UI.

**F1 result (2026-10-25).** Built: `AudioFileSource` (AVAssetReader → 16 kHz
mono Float32, one-second contiguous chunks, `isFinal` on the last, named errors
for unreadable, no audio track, protected content, empty), `FileTranscriptionSession`
(offline, backpressure instead of loss, written once at the end so a cancel or
failure leaves no note), `MeetingPlatform.file`, and the Debug launch argument
`--transcribe-file PATH [--language de] [--window-min S --window-max S]
[--store-dir DIR] [--transcript-out F] [--json-out F]`. Tests:
`FileTranscriptionTests.swift` (chunk continuity, final chunk, stereo 44.1 kHz
downmix, full-file coverage with no lost interval, cancellation leaves no note,
named file errors, mid-file read failure, unavailable model, a full queue waits
instead of dropping, progress and time-left extrapolation, window bounds).

Measured on an Apple M1 with 16 GB, the lowest Apple Silicon the product
supports, running the Debug build, files as 48 kbps AAC `.m4a`, German and
English profile pinned, windows 15–28 s unless stated. Real-time factor (RTF)
is recognition wall time per second of audio, model preparation excluded.

| File | Audio | Windows | RTF | Lost intervals | Peak footprint | Peak resident | WER |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| DE interview, 15–28 s windows | 60.7 min | 218 | 0.169 | 0 | 104 MB | 1376 MB | 0.25 % (20 / 7955) |
| EN interview, 15–28 s windows | 60.7 min | 219 | 0.166 | 0 | 105 MB | 1432 MB | 0.28 % (26 / 9234) |
| DE interview, 8–20 s windows (live sizes) | 60.7 min | 392 | 0.164 | 0 | 97 MB | 1477 MB | 0.64 % (51 / 7955) |
| DE interview, 3 h, 15–28 s windows | 180.2 min | 645 | 0.190 | 0 | 251 MB | 349 MB | not scored |
| DE, 10 min | 10.3 min | 37 | 0.155 | 0 | 98 MB | 1416 MB | 0.15 % (2 / 1356) |
| EN, 10 min | 10.5 min | 39 | 0.146 | 0 | 114 MB | 272 MB | 0.26 % (4 / 1562) |

- **The gate holds.** An hour of audio is recognised in about ten minutes, six
  times faster than the recording; memory is flat; no interval was lost; each
  run's last row ends at the file's last frame.
- **Three hours.** 180 minutes were recognised in 34 minutes with no lost
  interval. The footprint outside the model grew from about 100 MB at one hour
  to 251 MB at three: the audio is bounded (a few windows at a time), but the
  assembler keeps every window's tokens with their timing for the whole note,
  so memory follows the length of the transcript, roughly 50-75 MB per audio
  hour. That is harmless at the lengths people bring and would matter near ten
  hours; dropping tokens that no row needs any more is the fix if it ever does.
  This run overlapped with a Release build and the full test suite, which is
  why its RTF (0.190) is the highest.
- **Window sizes: 15–28 s stays.** Against the live sizes it cuts the word
  error rate from 0.64 % to 0.25 % on the same file with no cost in speed
  (RTF 0.164 against 0.169) and nearly halves the decode calls (218 against
  392). `FileWindowSizes.file` is the default; `.live` is kept for comparison.
- **What these numbers are not.** The audio is macOS text-to-speech, two voices
  alternating, with pauses of 0.4–2 s and one in about twenty-five turns
  followed by an 8–15 s gap. Reference text is the text that was spoken, so the
  word error rate is a floor for clean speech, not a prediction for a real
  interview. The plan's "2 × 10 minutes of consented recordings per language"
  is **not met**: no consented recording exists in the repository or on this
  Mac. Real-speech WER stays an open measurement; nothing may be said about
  accuracy on the site or in the ad until it exists.
- **Concurrency.** The runs shared the machine with text-to-speech generation,
  Xcode builds and test runs, so the RTF spread (0.146–0.169) is a bound, not a
  benchmark of an idle Mac.
- **First-run cost is the real risk, not the long file.** Time from launch
  until the model could take the first window was 592 s, 960 s, 847 s and
  1112 s in four runs (Core ML compiling the model for this Mac's Neural
  Engine) and 4 s in the fifth. The cause of the difference was not isolated;
  free disk space on the machine was between 1.8 and 8 GB, which macOS may
  answer by purging compiled caches. Dictation already tells the person about
  this wait; the file window says "Preparing the speech model…" and can be
  cancelled, but a person who drops a file on a fresh install can wait a
  quarter of an hour before progress moves. The release check below includes a
  clean-Mac run for that reason.
- Tools: `Tools/make_synthetic_interview.py` builds the files and the reference
  with true speaker turns, `Tools/file_wer.py` scores a transcript.

### F2 — speakers for files

- Run `BundledNemotronSpeakerDiarizer` over the file's chunks; align and build
  rows with the existing aligner and row builder.
- Measure on consented two- and three-person interviews in German and English:
  at least 10 recordings and 10 scored minutes per language, speaker error rate
  at or below the 20% threshold `DiarizationQualityGate` already uses. File
  interviews are a narrower and easier target than the meeting corpus, and the
  gate is applied to this category only.
- Bundling the Core ML model in the ordinary Release DMG is a distribution
  decision (size, update, notices). Record it here before it is made.
- Gate failure does not block the slice: rows ship unlabelled, the user assigns
  `Speaker 1…8` manually, and the site and the ad do not mention automatic
  speaker detection.

**F2 result (2026-10-25).** Built: the session takes an optional streaming
diarizer, feeds it the same one-second chunks the windows are cut from, and
builds rows with the existing `SpeakerAttributionAligner` and
`SpeakerAttributedRowBuilder`. Speakers are named `Speaker 1…8` in the
manifest and can be renamed or reassigned in the library. Any failure,
whether the model cannot prepare or inference stops halfway, drops the labels
for the **whole file** and says so in the result (`speakersLabelled = false`):
labels for the first half of a recording and none for the rest would read as a
finding. Tests use a scripted diarizer for the three paths (labelled,
cannot prepare, fails at minute five).

**The quality gate was not measured, and the decision is the plan's failure
path.** It needs at least ten consented two- and three-person interviews and
ten scored minutes per language at or below 20 % speaker error. There are no
consented recordings, and synthetic two-voice speech (voices that differ in
every feature a diarizer uses) would pass a test it says nothing about. The
Core ML model is also not on this Mac: `Tools/prepare_nemotron3_model.sh`
downloads it from Hugging Face, and that was not done without being asked.

Decided and recorded:

- **No automatic speaker labels in the ordinary build.** `FileSpeakerPolicy`
  hands the session no diarizer unless the build sets `FILE_SPEAKER_LABELS`
  (which also needs `NOTETAKER_DIARIZATION` and the bundled model, as the
  dogfood DMG has). People assign speakers by hand; the library already
  supports it and its help text says automatic numbering is off.
- **The model is not bundled in the Release DMG.** No size change, no new
  third-party notice beyond what the merge already carries, no update path to
  maintain. Revisit when the gate has data.
- **The site and the ad do not mention automatic speaker detection.** The
  comparison page says the opposite, in the website branch.
- Still open: whether FluidAudio's offline path beats feeding the streaming
  adapter on whole files. It is unmeasured.

### F3 — product UI and exports

- Menu item `Transcribe audio file…`, drop target, `NSOpenPanel` limited to
  the supported types.
- Progress window: file name, progress bar, elapsed, time left, Cancel; the
  menu-bar item shows that a file is running.
- Result opens in `MeetingLibraryWindow`; file notes show the source file name
  and duration instead of meeting platform.
- DOCX, SRT, QDA-timestamp exports. Replay a row from the original file.
- German and English strings in `Localizable.xcstrings`.

**F3 result (2026-10-25).** Built:

- **Entry points.** *Transcribe audio file…* and *Transcripts* in the menu bar
  window; one window that is a drop target and a Choose file… button while
  idle, a progress panel (file name, bar, elapsed, about how long is left,
  Cancel) while a file runs, and a named explanation when it could not. The
  menu bar symbol changes while a file runs. When a file finishes the window
  closes and the library opens on its note.
- **Dictation and files share one engine.** `DictationCoordinator` answers a
  press during a file with the notice "Witness is transcribing a file" and
  records nothing, in the same panel and on the same path as the wait for the
  speech model. A locked Mac gets the paywall instead of a file; a finished
  file that produced text counts as the first dictation does
  (`recordSuccessfulDictation`), starting the ungated window and the trial.
- **Library.** File notes show the file name and duration in the header; each
  passage has a play button that decodes that stretch of the original again
  and says so if the file has moved. The manifest keeps `sourceFile`
  (name, path, duration) as an optional field, so earlier notes still decode.
- **Exports.** DOCX (AppKit's own writer, no dependency), SRT, text with
  timestamps, plus the existing text and Markdown. All use the current
  speaker names and the stored text. Uncertain passages keep a visible
  `[check this passage]` mark in text, Markdown, timestamped text and DOCX
  (highlighted); SRT has none because it would be shown on screen.
  SRT cues are two lines of at most 42 characters, with a row's time shared
  between its cues by length.
- **German and English** for every new string and for the library surface, in
  `Localizable.xcstrings` (`Tools/add_localizations.py` adds entries without
  reformatting the file).

Timestamped text is `Speaker: #hh:mm:ss-d# text`, one line per turn. The
syntax `#hh:mm:ss-x#` is the one MAXQDA documents for f4/f5 transcripts and
ATLAS.ti lists among the timestamp formats it reads (their help pages, checked
2026-10-25). Not verified: an actual import into either program, and MAXQDA's
note that it recognises stamps at the end of a paragraph, whereas this puts the
stamp where the turn starts. Until someone imports a file, the menu says "Text
with timestamps" and neither the app nor the site names a program.

Not built, deliberately: editing the text of a row (the stored record keeps
one text and the raw recognition; speakers, titles and notes are editable);
the "no meeting while a file runs" rule in the other direction (meetings are
absent from the ordinary build, and `isMeetingActive` is `false` in it; wire it
before the dogfood facade and files are ever enabled together); batch queues.
The library's own English wording is still meeting-centric ("Meeting title",
"Start meeting note" hidden for files) and wants a pass before the library is
presented as the home of transcripts.

### F4 — release

- New compile-time flag `FILE_TRANSCRIPTION`, independent of
  `NOTETAKER_DOGFOOD`. The ordinary Release build enables file transcription
  and the meeting library it needs, and nothing that captures system audio or
  detects meetings.
- Telemetry, enum cases only: `fileTranscriptionStarted`,
  `fileTranscriptionCompleted(DurationBucket)`,
  `fileTranscriptionFailed(FileTranscriptionFailure)`. Duration is a bucket,
  never a value derived from content; no file name, type or language is sent.
  Disclose each in the privacy policy before shipping.
- Update `docs/PRIVACY.md`, the in-app privacy text, and
  `website/app/_data/comparisons.ts`, which currently answers "Nein. Witness
  transkribiert keine Dateien…" (line 865).
- Release gate: F1 metrics recorded, F2 decision recorded, dictation
  regression suite passes, a notarized build transcribes a 60-minute German
  interview end to end on a clean Mac.

**F4 result (2026-10-25), and what is still the owner's before a release.**
Built:

- **Flag.** `FILE_TRANSCRIPTION` is set for Release in the project's build
  settings (and is always on in Debug); `FileTranscriptionAvailability` is its
  single gate, independent of `NOTETAKER_DOGFOOD`. The ordinary build has file
  transcription and the library it needs, and no system-audio capture, meeting
  detection or diarizer. `FileTranscriptionCompositionTests` asserts that
  enabling files leaves the meeting facade off.
- **Telemetry.** Three enum events, `file_transcription_started`,
  `file_transcription_completed` (audio length as `underFiveMinutes`,
  `underThirtyMinutes`, `underTwoHours` or `overTwoHours`) and
  `file_transcription_failed` (`unreadable`, `noAudioTrack`, `protectedContent`,
  `empty`, `modelUnavailable`, `recognitionStopped`, `storageFailed`). A cancel
  and the refusals before a file is touched send nothing. They go through the
  same five-field body, the same Settings → Privacy switch and the same
  90-day retention as the other nine; unlike the setup milestones they are
  sent for every file, because the number of files is what they count. The
  service allow-list, schema and a rebuild migration are in `Service/`.
- **Disclosure.** `docs/PRIVACY.md` (new section "Files you transcribe", the
  table row, the event table, the qualifier lists, "twelve" throughout), the
  first-run privacy sentence and the Settings switch label, in English and
  German. `PrivacyDisclosureTests` and `TelemetryBoundaryTests` now assert
  twelve.
- **Website.** The MacWhisper comparison and the comparison hub said Witness
  does not transcribe files, make subtitles or detect speakers. They now say
  what is true: single files, exports including SRT, no automatic speaker
  detection, no batches, meetings or links. That change is a branch of the
  website repository (`claude/witness-transcribes-files`, one commit,
  `npm test` passes) and is **not** merged: it must go live together with the
  release, not before.

Before the release, in this order (none of these can be done from here):

1. Run `Service/migrations/002-file-transcription-events.sql` on the remote D1
   database, then deploy the Worker. The other order loses events silently.
2. Publish the privacy page from `docs/PRIVACY.md` (`/datenschutz`) before the
   version ships, as the document itself requires.
3. Notarize and, on a clean Mac, transcribe a 60-minute German interview end
   to end, including the first-run model preparation (10-18 minutes were seen).
4. Record real-speech word error rate on consented recordings, or keep every
   accuracy claim off the site and the ad.
5. Merge the website branch with the release.

## Out of scope for the first release

- Batch queues of many files, folder watching.
- Transcribing a URL or a YouTube link (the paid-search plan excludes
  `youtube` as a negative keyword for the same reason).
- Translation, summaries and Q&A; Notetaker Slice 7 can add them to file notes
  later because both live in the same store.
- Recording a new file inside Witness; dictation and meetings already cover
  live audio.
- Windows.

## Open questions

- Exact MAXQDA / f4 / ATLAS.ti timestamp syntax that imports cleanly.
- Whether the offline (non-streaming) diarization path in FluidAudio is more
  accurate than feeding the streaming adapter, for whole files.
- How long a single file may be before peak memory of the assembler and store
  matters: measured to 3 h in F1 (251 MB, linear in transcript length); not
  measured beyond.
