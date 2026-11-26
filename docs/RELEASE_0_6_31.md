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
