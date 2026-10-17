# Phase 9 cleanup baseline

The Debug target contains a text-only Flow-Light manifest and scorer in
`LocalDictation/Benchmark`. The same manifest can be run against Conservative
and Clean cleanup. It reports edit precision/recall, protected-value
preservation, punctuation and line-break F1, correction effort, and p50/p95
processing time by language.

The committed deterministic baseline fixtures pass unchanged through
`ConservativeCleanupService`. The private, consented DE/EN/RU/UK speech corpus
remains outside this repository and must be run before Clean can become the
fresh-install default. No release-gate result is claimed by this document.
