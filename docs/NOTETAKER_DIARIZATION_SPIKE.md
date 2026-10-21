# Notetaker numbered-speaker spike

Slice 6 adds the local plumbing needed to evaluate numbered speakers without
turning an unmeasured hypothesis into a product claim. The shipping fallback is
still the independently captured `You` and `Others` sources.

## Dependency and licence gate

This slice adds no package, model, downloaded weight, permission, system-audio
capture path, persistence framework, or network request. The experiment is
first-party Swift source in the app and uses only the already captured in-memory
16 kHz mono system-audio chunks. There is therefore no new third-party SDK or
model licence to approve in this implementation.

FluidAudio and other diarization SDKs remain intentionally unintegrated. Before
one can be considered, record the exact SDK commit, every transitive licence,
the model source and licence, redistribution terms, model size, and whether the
implementation can release audio incrementally. A requirement to persist the
whole recording is a privacy decision, not an engineering shortcut.

## Experiment

`ExperimentalLocalSpeakerDiarizer` computes a small acoustic fingerprint in
memory, clusters consecutive system-audio frames into at most three anonymous
speakers, and supports both incremental chunks and an offline in-memory call.
It is deliberately a plumbing experiment, not a production speaker embedding.
`UnavailableSpeakerDiarizationService` remains the product default and emits no
hypotheses.

`SpeakerAttributionAligner` overlaps diarizer turns with transcript segments and
timed words. Each proposed segment and word retains an explicit `0...1`
confidence. Nothing in the experiment infers or imports a real person's name.

Saved transcript rows now preserve both current and original attribution. A
manual reassignment changes only the current speaker ID; restoring it recovers
the original ID, source, and confidence. Speaker display names live in the
meeting manifest and affect only that meeting and its exports. Atomic transcript
replacement is used for post-recording edits. No audio or acoustic fingerprint
is written to disk.

## Corpus gate

Automatic numbered labels stay off unless all four consented-corpus categories
meet the checked-in `DiarizationQualityGate`: at least 10 recordings and 10
scored minutes per category, with speaker error rate no greater than 20% in each
category. Aggregate accuracy cannot hide a weak category.

| Required category | Recordings | Scored time | Speaker error rate | Result |
| --- | ---: | ---: | ---: | --- |
| Overlapping speech | Not measured | Not measured | Not measured | Fails closed |
| Short turns | Not measured | Not measured | Not measured | Fails closed |
| Similar voices | Not measured | Not measured | Not measured | Fails closed |
| Shared-room microphones | Not measured | Not measured | Not measured | Fails closed |

These are not zeroes. No licensed, consented real-speech corpus was supplied for
this slice, and synthesized tones are only a deterministic plumbing test. The
quality gate therefore fails, so the test build keeps automatic `You`/`Others`.
The meeting library does allow an explicit user to assign `Speaker 1/2/3`, rename
those labels, and restore the original attribution.

## Verification

Deterministic tests cover unavailable fallback behavior, streaming and offline
memory-only clustering, silence, segment/word alignment confidence, gate
fail-closed behavior, backward-compatible transcript decoding, atomic manual
reassignment, rename/export behavior, and restoration of original attribution.
The normal Xcode test suite and an ad-hoc dogfood DMG build remain the slice
release checks.
