# File transcription — implementation plan

Status: F0 done 2026-10-25 (merge commit `8fca788` on
`claude/file-transcription-stages-11a7ec`); F1 onward in progress. This document is the implementation
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

### F3 — product UI and exports

- Menu item `Transcribe audio file…`, drop target, `NSOpenPanel` limited to
  the supported types.
- Progress window: file name, progress bar, elapsed, time left, Cancel; the
  menu-bar item shows that a file is running.
- Result opens in `MeetingLibraryWindow`; file notes show the source file name
  and duration instead of meeting platform.
- DOCX, SRT, QDA-timestamp exports. Replay a row from the original file.
- German and English strings in `Localizable.xcstrings`.

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
  matters (measure 3 h in F1).
