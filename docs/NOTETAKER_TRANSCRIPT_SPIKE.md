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

This remains an internal test path, not a released meeting recorder. The
command-line Debug harness has Start and Stop; the dogfood build below adds the
native test interface. Neither is a substitute for a consented hardware test.
Headphones are the supported test configuration; echo
on speakers has not been measured. In the dogfood build, closing the meeting
window leaves an active recording running; the separate `Meeting recording`
menu-bar item reopens, pauses/resumes or stops it. The harness displays
inference time divided by captured meeting time, audio real-time factor, maximum queue delay, peak
queue depth, process peak resident memory, skipped silent windows and detected
lost intervals. These are local engineering diagnostics, not validated
benchmark results. A lost interval is a detected callback/queue discontinuity,
not a claim that every inaudible or semantically missing word can be counted
automatically.

## Installable dogfood build

An internal Release DMG can expose the native meeting window without enabling
Notetaker in ordinary Release builds:

```sh
NOTETAKER_DOGFOOD=1 Tools/build_test_dmg.sh
```

The dogfood window is opened from `Start meeting note…` in the Witness menu.
It lists Core Audio processes, prefers active Zoom or Chrome processes, accepts
one verified transcript language, supports Start/Pause/Resume/Stop, displays
source health and elapsed captured time, and keeps the live transcript and
technical metrics in memory. Completed and partial transcripts are stored
locally without audio. `Meeting note history…` opens the searchable local
library, where a tester can rename a note, edit notes, inspect transcript and
raw recognition differences, export text or Markdown, and permanently delete
the meeting after confirmation. Empty, loading, partial and failure states are
explicit. The reminder about applicable recording rules is informational and
does not block Start. No bot joins the meeting and Witness does not send a
participant notification.

The ordinary build omits `NOTETAKER_DOGFOOD`, so its composition root remains
disabled and constructs none of this UI or its system-facing dependencies.

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
