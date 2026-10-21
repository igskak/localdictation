# Notetaker Slice 5 — local meeting detection

## Privacy boundary

Detection reads the local Core Audio process inventory and the matching running
application identity. It does not read browser tabs, meeting or window titles,
URLs, participant data, audio samples, transcripts, or clipboard data. It does
not add a permission or a network request.

Zoom output is classified as confirmed Zoom activity. Chrome output is only a
probable Google Meet candidate because the privacy boundary deliberately avoids
checking which tab is producing that output. The UI says “Possible Google Meet”
instead of presenting that inference as fact.

## User control and call end

- Detection shows at most one suggestion for one uninterrupted candidate.
- Dismissal starts a 15-minute per-platform cooldown.
- Detection alone never starts capture. `Start note` on the card is an explicit
  user action; the manual `Record meeting note…` route remains available at all
  times.
- Loss of the selected process audio waits 30 seconds, then pauses capture. It
  does not finalize the note. Returning audio resumes the same in-memory and
  persisted meeting session. `Keep recording` disables this guard for the
  current session.
- Automatic recording remains off.

## Dogfood measurement gate

Counters are stored locally in
`Application Support/Witness/notetaker-detection-metrics.json`. The schema has
only true-positive, false-positive, and false-negative integer counters and
their calculated rates, split between `zoom` and `googleMeet`. No process identity, PID, title, URL,
participant, audio-derived value, or content is present. Nothing is uploaded.

For the dogfood build, accepting a matching detected candidate counts as a true
positive, dismissing it counts as a false positive, and manually starting a
supported meeting app that was not detected counts as a false negative. The
rates are:

- false-positive rate = FP / (TP + FP)
- false-negative rate = FN / (TP + FN)

Suggestions must not be enabled in the normal release build until both rates
have been measured separately for Zoom and Meet on the agreed test corpus and
the release thresholds are documented. `NotetakerAvailability.liveDefault`
therefore remains disabled without `NOTETAKER_DOGFOOD`.
