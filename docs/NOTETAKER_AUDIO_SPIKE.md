# Notetaker system-audio spike

The Debug-only process tap probe is opt-in and captures only in memory. It
emits duration, callback and drop counts; it does not log audio, levels, process
names, bundle identifiers or transcriptions. A successful run shows that
callbacks arrived without queue drops; it does not prove that the correct sound
was captured or that the speech is intelligible.

Start the Debug executable once with `--notetaker-audio-processes` to list the
Core Audio process IDs and whether each process currently has running output.
The inventory intentionally omits process names and bundle identifiers. Then
start it with `--notetaker-audio-spike PID SECONDS`, choosing the Core Audio
process ID of the consenting test application. Close any other Witness copy
first. macOS may request system-audio permission on first start. Use
headphones. Add `--notetaker-spike-pause` to exercise pause, drain and resume
halfway through the run. The probe stops and drains automatically at the end
and returns a nonzero status on an error, missing callbacks or queue drops. It
reports the peak and final queue depth plus the number of frames flushed at
pause/stop. Failures are reduced to content-free categories, including an
actionable `permission-denied` category. It does not save audio or produce a
recording for listening.

Chrome may render audio for several tabs in the selected process; the tap does
not guarantee capture of one Meet tab. Zoom and Chrome can use helper processes,
so the audio process ID must be identified through Core Audio rather than
assuming the UI application's PID.

Manual results are **not yet measured**. Validate Zoom and Chrome separately,
including a 60-minute session, pause/resume, stop, device changes, sleep/wake,
mute and permission revocation before considering the spike verified. Callback
counts alone cannot establish intelligibility or identify silent gaps. The
subsequent two-source benchmark needs consented speech data and actual target
hardware; no benchmark figures are claimed here.
