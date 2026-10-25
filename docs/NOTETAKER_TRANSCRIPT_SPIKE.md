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
`Others`. Recognition windows do not overlap and end in a pause: after eight
seconds a window waits for 300 ms that are quiet relative to its own speech
and is cut in the middle of them; without a pause it is cut at its quietest
stretch at twenty seconds. The first live text therefore still normally
appears after roughly 8–10 seconds, and no phrase is recognised twice. Fixed
twelve-second windows with a four-second overlap repeated 16–22% of the words
in the 23.10 dogfood meeting.
Each source keeps its own timeline the way a recorder writes a track: a chunk
starts where the previous one ended, and host time only corrects the position.
Within 20 ms the sample count wins, a late chunk is padded with up to 250 ms of
silence, a longer hole starts at its host-time position, and a chunk that
claims audio already handed out loses the overlap. A device clock drifting
from the host clock is therefore never fatal; on 23.10 one backward correction
after 29 minutes ended the meeting as `transcription_missing_audio`.
Each meeting takes the complete ordered language profile from Witness settings
when recording starts. There is no separate Note Taker language choice and no
hidden English default; a settings change applies to the next meeting instead
of changing the decoder halfway through an active transcript.
When a callback is dropped, the harness records a lost interval, marks the note
partial, keeps the real host-time gap, and continues capturing. A fatal capture
or inference failure still stops the affected pipeline, flushes already valid
audio for transcription, and marks the transcript partial. The final status
names the locally known failure class rather than collapsing every partial note
into one generic message. Silence is measured and skipped without changing
later timeline positions. It retains the raw recognition output behind the
presentation and only removes time-aligned boundary repeats whose text is exact
apart from punctuation. Adjacent supported windows by one speaker are grouped
into readable turns; recognition at or below the product's calibrated
confidence threshold is separated and labeled as a model guess in both the
live view and history. The process tap may include other Chrome tabs.

This remains an internal test path, not a released meeting recorder. The
command-line Debug harness has Start and Stop; the dogfood build below adds the
native test interface. Neither is a substitute for a consented hardware test.
Headphones are the supported test configuration. On speakers the
meeting microphone opens with Apple voice processing (other apps are ducked as
little as the unit allows) and falls back to the direct input if it will not
open; the log says which. A microphone row is then removed as echo when at
least 60% of its words were recognised in system audio within two seconds,
and the metrics count the removed rows. The live file keeps every row for
crash recovery; the final transcript is the filtered one. How much echo voice
processing cancels from another app's playback has not been measured. In the dogfood build, closing the meeting
window leaves an active recording running; the separate `Meeting recording`
menu-bar item reopens, pauses/resumes or stops it. The harness displays
inference time divided by captured meeting time, audio real-time factor, maximum queue delay, peak
queue depth, process peak resident memory, skipped silent windows and detected
lost intervals. These are local engineering diagnostics, not validated
benchmark results. A lost interval is a detected callback/queue discontinuity,
not a claim that every inaudible or semantically missing word can be counted
automatically. A forward host-time gap with a continuous callback sequence is
treated as a recoverable delivery gap for either source: the current window
closes and the next one keeps its real timeline position without inventing
samples. This covers normal process-tap silence and temporary microphone delay
while macOS shows system UI such as the screenshot overlay.

## Installable dogfood build

An internal Release DMG can expose the native meeting window without enabling
Notetaker in ordinary Release builds:

```sh
NOTETAKER_DOGFOOD=1 Tools/build_test_dmg.sh
```

The dogfood window is opened from `Start meeting note…` in the Witness menu.
It lists Core Audio processes, prefers active Zoom, Chrome, or Safari processes, accepts
the user's full Witness language profile, supports Start/Pause/Resume/Stop, displays
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

The 60-minute two-source gate, Zoom/Chrome/Safari process-tap stability, device and
permission changes, and speaker echo remain unverified. Collect the metrics on
the target Mac using consented speech before claiming a successful beta.
