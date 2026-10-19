# Phase 9.1 release gate

Status: **in progress; not cleared for release or Clean-by-default**.

The synthetic baseline is recorded in `PHASE_9_1_BASELINE.md`. The current
implementation has a composed Conservative pipeline with a limited set of
Russian and Ukrainian detached marker repairs and a complete spaced clock
shape and English percentage spacing; ephemeral validated timing evidence and
a boundary-duplicate repair gated on explicit segment provenance and identical
timestamps (currently unavailable from the transcription adapter); more conservative
explicit-list handling; code and terminal category handling; and sentence,
paragraph, and timing-bounded implicit-list paths guarded by disabled policies.
No production language policy is enabled for these inferred structures. A
synthetic benchmark can compare cleanup modes and check lexical preservation
and idempotence; it is not evidence of real-speech accuracy.

The implementation is incomplete: the remaining surface-equivalence and
symbol rules, transcription adapter segment provenance and broader timing-proven
duplicate handling, corpus-calibrated
structural, paragraph, and implicit-list policies, broader correction and
adversarial coverage, complete benchmark comparisons, and settings explanations
still need to be implemented and verified. The tests and Release builds recorded for the
individual commits do not establish the release thresholds below.

The private consented DE/EN/RU/UK corpus and per-language precision and recall
reports have not been supplied. The required manual application matrix,
ten-minute soak, blinded preference comparison, Wispr Flow reference and p95
latency evidence have not been recorded. Neither these requirements nor the
Phase 9 gates can be marked passed from synthetic fixtures. Keep the
fresh-install default Conservative, and leave all structural timing policies
disabled until the required evidence has been independently measured and the
remaining implementation is complete.
