# Witness 0.6.31 (34)

Notetaker Beta revisits recent speaker attribution while the conversation
continues. Text appears as soon as speech recognition produces it. A later
pass can update speaker labels and split previously displayed recognition
windows at a supported handoff. Ambiguous passages stay under Others.

On macOS 15 and later, the preferred diarizer is FluidAudio's Community-1
Core ML pipeline. It reviews up to 32 seconds of system audio every 10 seconds
after the initial 12 seconds of audio, and checks the remaining tail at stop.
Only one review runs at a time. Recent acoustic evidence and session-local
embeddings are available for matching the same voice across overlapping
windows. Audio and embeddings stay in memory and are released on stop. On
macOS 14 or if preparation fails, the existing local Nemotron engine provides
live attribution updates. The microphone has its own You label.

## Model provenance

The release uses the existing FluidAudio 0.17.7 dependency. The added model is
the Community-1 subset of FluidInference's speaker-diarization-coreml at
[revision 7eab74f](https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/7eab74f3463c736418d0eb10296261ae581146c9).
The build script pins SHA-256 for the four compiled models and PLDA parameters
and bundles the upstream CC BY 4.0 license, attribution notice, and citations.
The notice attributes pyannote, WeSpeaker, BUT Speech@FIT, and Fluid Inference.
These are modified Core ML conversions. Upstream describes the exact historical
conversion revision as unverified in its provenance record.

The app opens the bundled models at explicit local paths. It uses the
in-memory diarization API. Crash recovery stores recognized text windows;
the finalized file atomically replaces them with the revised transcript.

## Benchmark protocol

The optional XCTest `testLocalAMIEngineComparison` replays 12 48-second
excerpts of EN2002c from the [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/download/)
(CC BY 4.0) through the existing streaming engine and the new rolling path.
It takes a local fixture directory through `WITNESS_SPEAKER_BENCHMARK_DIR`
containing `EN2002c.wav` and `community-models/`, and a local Nemotron model
directory through `WITNESS_NEMOTRON3_TEST_MODEL_DIR`. The score uses the AMI
manual word timestamps and a one-to-one label mapping per excerpt. A handoff
is counted as correct if the two consecutive reference words from different
participants, with no overlap and at most one second between them, are both
assigned correctly at their midpoints. This check is specific to one English
meeting and does not measure the original Daily.

| Path | Correct speaker at word midpoint | Correct handoffs | Median inference time per 48 seconds |
| --- | ---: | ---: | ---: |
| Existing streaming Nemotron | 564 / 1,916 | 3 / 70 | 0.37 s |
| Community-1, complete excerpt | 1,445 / 1,916 | 7 / 70 | 1.33 s |
| Community-1, rolling production algorithm | 1,415 / 1,916 | 10 / 70 | 3.71 s |

Measured on a MacBookPro17,1 running macOS 26.6.2. Handoff accuracy remains
low on this replay. The native Xcode suite reported 1,292 passed and 11
skipped, with no failures.

## Published artifact verification

- Published as the latest stable release on 26 November 2026 at 23:34
  Europe/Warsaw. The [v0.6.31 tag](https://github.com/igskak/localdictation/releases/tag/v0.6.31)
  points to `121e3a7cf518b2d5df8c8e9301d9f80f40933551`.
- Apple notarized the app (`2d9043a1-7799-4b9e-b7f3-7e7c10c52262`) and the
  disk image (`30abf1c9-aaf2-4bc0-9657-ef191c054dff`). Both tickets are
  stapled and validated. Gatekeeper accepted both artifacts.
- The 0.6.30 public release key verifies the 0.6.31 Sparkle feed and disk
  image. The live feed and website download returned HTTP 200 and matched
  the signed release files byte for byte.
- DMG SHA-256 is `379648d3f5eaede897ddc32d8004aa838199c182a31f880b8ef8aa6448609fdb`.
  Appcast SHA-256 is `01753693dce25abafdb57b95db5d9b9e800d2e916d98b64a1bdb23de6ceb46d1`.
