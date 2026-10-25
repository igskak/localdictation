# Notetaker Slice 5 — local meeting detection

## Privacy boundary

Detection reads the local Core Audio process inventory and the matching running
application identity. It does not read browser tabs, meeting or window titles,
URLs, participant data, audio samples, transcripts, or clipboard data. It does
not add a permission or a network request.

Zoom output is classified as confirmed Zoom activity. Chrome output is only a
probable Google Meet candidate because the privacy boundary deliberately avoids
checking which tab is producing that output. Safari output is a separate
probable Safari-call candidate and never claims to know the service or tab. The
UI uses “Possible” for both browser cases instead of presenting inference as
fact.

When multiple supported processes are available, active output wins over an
open but silent application. Zoom remains the highest-confidence native signal.
Between active Chrome and Safari processes, a process currently using the
microphone wins, then the frontmost browser. These are local Core Audio and
application-state signals only. Witness does not read URLs, tab titles, window
titles, or page contents. A deterministic fallback is used when those signals
tie, and the selected source remains visible in the recording window.

## User control and call end

- Detection shows at most one suggestion for one uninterrupted candidate.
- Dismissal starts a 15-minute per-platform cooldown.
- Detection alone never starts capture. A compact non-activating panel offers
  `Start recording` or `Not now` without taking focus from the meeting app; the
  menu-bar card and manual `Record meeting note…` route remain available. The
  start panel disappears after five seconds and enters the normal cooldown;
  that timeout is not counted as a false positive because the user did not
  reject the detection.
- Loss of the selected process audio waits 30 seconds, then shows a compact
  `Stop recording` / `Keep recording` prompt. Capture continues throughout:
  silence, helper-process churn, and the presumed end of a call can never pause
  or finalize a note without an explicit user action. Returning audio dismisses
  the prompt; `Keep recording` suppresses it for the current session.
- Automatic recording remains off.

## Dogfood measurement gate

Counters are stored locally in
`Application Support/Witness/notetaker-detection-metrics.json`. The schema has
only true-positive, false-positive, and false-negative integer counters and
their calculated rates, split between `zoom`, `googleMeet`, and `safari`. No
process identity, PID, title, URL, participant, audio-derived value, or content
is present. Nothing is uploaded. Schema 2 migrates existing schema-1 Zoom/Meet
counters and initializes only the new Safari bucket.

For the dogfood build, accepting a matching detected candidate counts as a true
positive, dismissing it counts as a false positive, and manually starting a
supported meeting app that was not detected counts as a false negative. The
rates are:

- false-positive rate = FP / (TP + FP)
- false-negative rate = FN / (TP + FN)

Suggestions must not be enabled in the normal release build until both rates
have been measured separately for Zoom, Meet in Chrome, and browser calls in
Safari on the agreed test corpus and
the release thresholds are documented. `NotetakerAvailability.liveDefault`
therefore remains disabled without `NOTETAKER_DOGFOOD`.

## Public-behavior reference

The priority design uses only Wispr Flow's public product behavior as a UX
reference: its documentation treats microphone use as a meeting signal and
separates generic system-audio capture from higher-confidence, recognized-tab
behavior. Its documentation currently says Safari is unsupported for automatic
Google Meet speaker naming. Witness therefore does not copy that claim or infer
a tab identity; it adds generic Safari capture with anonymous speakers and an
explicitly probable detection label.

- <https://docs.wisprflow.ai/articles/4091106439-The-live-transcript-in-Notetaker>
- <https://docs.wisprflow.ai/articles/9319084321-Notetaker-settings%2C-explained>
