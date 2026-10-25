# Notetaker Slice 6.1 — production diarization model gate

Status: dogfood implementation ready for measured evaluation. This slice is
separate from the completed numbered-speaker plumbing in Slice 6. Automatic
numbered labels are enabled only in an explicitly built Notetaker dogfood DMG;
ordinary Release builds still fail closed to `You`/`Others` until the corpus
and 60-minute gates below pass.

## Pinned dogfood implementation

- Runtime: FluidAudio `0.17.7`, commit
  `503b4bd1bbf7220882de39fe8ae6716aae4132da`, pinned exactly through the local
  `WitnessDiarizationRuntime` package. Optional package traits are disabled.
- Model: `FluidInference/nemotron-3-diarization-coreml`, revision
  `25a90f97f254428d4b30374b76af9c74fdee8327`, profile
  `Nemotron3Diarizer_c128_split_w8a8.mlmodelc`.
- Distribution: the hash-verified model is injected into the signed app only by
  `Tools/build_test_dmg.sh` when `NOTETAKER_DOGFOOD=1`. Weights are neither
  committed nor downloaded at runtime. The app can run the feature offline.
- Processing: system/process-tap audio is sent to the model incrementally from
  memory. The independent microphone remains `You`; only remote system audio
  may receive anonymous `Speaker 1...8` labels. Audio and embeddings are never
  persisted.
- Failure behavior: a missing model, invalid audio format, model-load failure,
  inference failure, or discontinuity is visible locally and preserves the
  transcript via the existing `You`/`Others` fallback.
- Notices: the app bundle includes the Apache-2.0 FluidAudio license and the
  OpenMDW 1.1 model notice. The model preparation script pins and verifies the
  SHA-256 of all six downloaded files before packaging.

The selected c128 split profile is the accuracy-first dogfood candidate. Model
card results were used only for candidate selection; they do not satisfy the
Witness quality gate. The model uses a roughly 10.6-second inference window,
so speaker labels may appear after transcript text and must be evaluated for
perceived latency as well as final accuracy.

## Outcome

Select and measure a production-quality local diarization implementation for
the already captured system/process-tap audio. The microphone remains the
authoritative `You` source. The diarizer may propose only anonymous remote
labels such as `Speaker 1`; it does not infer a person's real identity.

The primary implementation candidate is NVIDIA Nemotron 3 Diarization converted
to Core ML and integrated through a pinned FluidAudio release. pyannote
Community-1 is the offline comparison baseline. ECAPA-TDNN, WeSpeaker/CAM++,
TitaNet, and 3D-Speaker remain candidates for a later, explicitly enrolled
known-speaker feature; their verification EER is not evidence of end-to-end
meeting diarization quality.

Primary references:

- FluidAudio: <https://github.com/FluidInference/FluidAudio>
- Nemotron 3 model card: <https://huggingface.co/nvidia/Nemotron-3-Diarization>
- Nemotron 3 Core ML conversion: <https://huggingface.co/FluidInference/nemotron-3-diarization-coreml>
- OpenMDW 1.1 model licence: <https://openmdw.ai/license/1-1/>
- pyannote Community-1 baseline: <https://huggingface.co/pyannote/speaker-diarization-community-1>

Published benchmark numbers are used only to choose what to test. They are not
accepted as Witness quality evidence because datasets, collar, overlap scoring,
hardware, and speaker-count assumptions differ between reports.

## Licence and provenance gate

The dogfood integration records:

- the exact FluidAudio release or commit and every transitive dependency;
- the exact model revision, file hashes, size, source, and redistribution terms;
- the Apache-2.0 notices for FluidAudio and the OpenMDW 1.1 notices for the
  Nemotron model artifact;
- the provenance limitations of any converted artifact and the upstream model;
- that the model is bundled only in dogfood DMGs, including the privacy, update,
  size, and offline-first consequences of that choice.

A repository licence does not automatically license its model weights. A failed
or ambiguous review blocks integration rather than silently substituting a
different checkpoint.

## Technical spike

The candidate remains behind the `NOTETAKER_DIARIZATION` build flag and the
existing service boundary. FluidAudio is visible only to the production
diarization adapter, not meeting storage, UI, or the transcription coordinator.

Evaluate at least the Core ML `fast32`, `fast128`, and compressed 95 MB profiles
on the minimum supported Apple Silicon hardware. The implementation must:

- consume 16 kHz mono system/process-tap chunks from bounded memory;
- preserve the independent microphone/`You` source;
- support overlapping remote speakers without manufacturing turn order;
- publish per-turn confidence into the existing alignment layer;
- release audio incrementally and never persist recordings or embeddings;
- remain functional with the network disconnected for the entire meeting;
- fail closed to `You`/`Others` when initialization, inference, speaker counting,
  or confidence is unsafe.

If acceptable quality requires saving a complete recording, stop for a separate
privacy decision. Temporary audio files are not permitted by this slice.

## Measurement corpus

Use only consented or appropriately licensed audio. Do not commit recordings,
transcripts, voiceprints, or downloaded weights. The corpus must cover DE, EN,
RU, and UK and retain the four existing mandatory categories:

- overlapping speech;
- short turns;
- similar voices;
- shared-room microphones.

Also record results separately for Zoom desktop and Google Meet in Chrome,
headphones and speaker playback, one/two/six remote speakers, mixed-language
turns, and a 60-minute continuous session. Synthetic fixtures remain useful for
determinism but cannot satisfy the quality gate.

Measure diarization error rate, word-level speaker error, speaker-count accuracy,
speaker confusion, overlap recall, p50/p95 attribution delay, real-time factor,
peak resident memory, energy impact, queue depth, lost intervals, and model load
time. Do not compare verification EER with diarization DER.

## Deliverables

- pinned dependency/model and completed licence/provenance record (implemented);
- reproducible local benchmark harness that does not upload content;
- dated result matrix with hardware, macOS, Zoom/Chrome, model profile, and
  scoring configuration;
- deterministic adapter, cancellation, bounded-buffer, failure, and fallback
  tests;
- a documented decision to integrate one profile or retain `You`/`Others`;
- third-party notices and dogfood-only distribution decision (implemented).

## Release gate

Automatic numbered speakers remain disabled unless:

1. Every mandatory corpus category has at least 10 recordings and 10 scored
   minutes with speaker error rate no greater than the existing 20% threshold.
2. The 60-minute run has bounded memory and queue depth, no silent interval loss,
   and stays ahead of real time on minimum supported hardware.
3. Overlap and uncertain attribution are shown honestly; manual reassignment and
   restore still preserve original evidence.
4. Offline operation, absence of persisted audio/embeddings, logs without
   content, exact licences, notices, and model hashes are verified.
5. Existing dictation, Notetaker, persistence, export, deletion, and disabled-
   feature regression tests still pass.

Failure keeps the production fallback at `You`/`Others`; it does not block the
useful transcript product or the following local-assistant work.

## Sequence after Slice 6.1

The next planned product slice remains **Slice 7 — local summary and
meeting-specific Q&A**. It can proceed independently while production
diarization remains disabled, because it consumes persisted transcript evidence
and must not depend on inferred speaker identity.
