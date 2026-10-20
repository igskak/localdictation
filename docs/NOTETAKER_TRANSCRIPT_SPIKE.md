# Notetaker two-source transcript spike

The experimental harness is available only in a Debug build launched with
`--notetaker-meeting-harness`. It requires the audio-producing process ID, an
already installed local speech model, microphone permission and explicit
participant notice or consent. Close other Witness instances before starting;
the harness does not yet share an audio or inference lease with them.
Use the Debug executable's `--notetaker-audio-processes` command while the
target meeting application is producing audio to find its Core Audio PID.

It captures microphone and a single Core Audio process on one host-time clock,
keeps raw audio only in bounded memory, and labels transcript rows `You` and
`Others`. When audio is dropped, inference fails or the queue fills, the harness
stops and marks the transcript partial. Silence is measured and skipped without
changing later timeline positions. It retains the raw recognition output behind
the presentation and only removes time-aligned boundary repeats whose text is
exact apart from punctuation. The process tap may include other Chrome tabs.

This is an engineering harness, not a released meeting recorder. It currently
has Start and Stop, not the later product UI, and is not a substitute for a
consented hardware test. Headphones are the supported test configuration; echo
on speakers has not been measured. Closing the window requests a stop. The harness displays inference time divided
by captured meeting time, audio real-time factor, maximum queue delay, peak
queue depth, process peak resident memory, skipped silent windows and detected
lost intervals. These are local engineering diagnostics, not validated
benchmark results. A lost interval is a detected callback/queue discontinuity,
not a claim that every inaudible or semantically missing word can be counted
automatically.

## Required measurements — not yet performed

| Language | Real-time factor | Peak memory | Queue delay | Lost intervals |
| --- | --- | --- | --- | --- |
| German | Not measured | Not measured | Not measured | Not measured |
| English | Not measured | Not measured | Not measured | Not measured |
| Russian | Not measured | Not measured | Not measured | Not measured |
| Ukrainian | Not measured | Not measured | Not measured | Not measured |

The 60-minute two-source gate, Zoom/Chrome process-tap stability, device and
permission changes, and speaker echo remain unverified. Collect the metrics on
the target Mac using consented speech before claiming a successful beta.
