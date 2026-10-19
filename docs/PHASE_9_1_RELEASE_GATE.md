# Phase 9.1 release gate

Status: **in progress; not cleared for release or Clean-by-default**.

The synthetic baseline is recorded in `PHASE_9_1_BASELINE.md`. The current
implementation has a composed Conservative pipeline with a limited set of
Russian and Ukrainian detached marker repairs and a complete spaced clock
shape; ephemeral validated timing evidence and a narrow identical-timestamp
boundary-duplicate repair; more conservative explicit-list
handling; code and terminal category handling; and a sentence-candidate
prototype which is not connected to output. No production language policy is
enabled for automatic sentence or paragraph boundaries.

The implementation is incomplete: the remaining surface-equivalence and
symbol rules, broader timing-proven duplicate handling, integrated structural and
paragraph inference, timing-bounded implicit lists, correction variants,
benchmark comparisons, and full documentation and settings work still need to
be implemented and verified. The tests and Release builds recorded for the
individual commits do not establish the release thresholds below.

The private consented DE/EN/RU/UK corpus and per-language precision and recall
reports have not been supplied. The required manual application matrix,
ten-minute soak, blinded preference comparison, Wispr Flow reference and p95
latency evidence have not been recorded. Neither these requirements nor the
Phase 9 gates can be marked passed from synthetic fixtures. Keep the
fresh-install default Conservative, and leave all structural timing policies
disabled until the required evidence has been independently measured and the
remaining implementation is complete.
