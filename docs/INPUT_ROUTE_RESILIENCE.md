# Input route resilience: implementation plan

Status: planned 2026-09-29, not started. Written for the session that
implements it; everything below was measured on the author's MacBook Pro
(built-in mic, macOS 26, Witness 8052 running, input preference
`systemDefault`).

## The problem

Dictation records silence while another app runs a call, and a recording ends
whenever the audio route changes. The bar is Wispr Flow: it keeps recording
through a Google Meet page opening and closing in Safari and transcribes the
whole utterance correctly (verified by the user on 2026-09-29, 51 s utterance,
Meet active for ~16 s in the middle).

## What was measured

### 1. A call page in Safari changes the microphone for everyone

Opening the Meet pre-join page in Safari starts Apple voice processing in the
WebKit GPU process (`VPAUAggregateAudioDevice-*` in the coreaudiod log). While
it runs, `MacBook Pro Microphone` reports **3 input channels instead of 1** to
every other client (`kAudioDevicePropertyStreamConfiguration`, input scope).
These are raw array channels, about **30 dB quieter** than the normal processed
channel:

| Path (RMS per second) | Speaking | Silent |
|---|---|---|
| Our own voice processing, during the call | -21 to -34 dBFS | -40 to -70 dBFS |
| Raw 3-channel mic, during the call | -50 to -63 dBFS | -65 to -85 dBFS |

For reference, the normal 1-channel mic without a call peaked at 0.2 to 0.5
while speaking (peak, not RMS; a different probe run). The raw channels do
carry speech: levels followed a speak/silent cue every 5 s.

Witness logged `Capture started: input 48000 Hz 3 ch` and
`Dictation produced nothing: silent:nothingHeard peak=0.000`.

### 2. Our converter turns multi-channel input into exact zeros

`AudioFormatConverter` builds an `AVAudioConverter` from the tap format to
16 kHz mono with `downmix = true`. For a 3-channel discrete input (no channel
layout) the output is **exactly 0.0000** while the input channels carry
signal. This is a bug independent of calls: any 3+ channel interface hits it.

### 3. We record through an aggregate clocked by the speakers

With `systemDefault`, `AVAudioEngine` records through a private
`CADefaultDeviceAggregate-<pid>-N` whose IO work loop is the default **output**
device (`IOWorkLoopInit: BuiltInSpeakerDevice (CADefaultDeviceAggregate-8052-9)`).
Output changes (AirPods connecting, HFP switching, a display) rebuild our input
path and raise `AVAudioEngineConfigurationChange`. On that notice the engine
stops and delivers **no buffers** until rebuilt; our recovery then ends the
utterance with `.inputDeviceChanged` whenever the format changed.

### 4. What Wispr Flow does (Wispr Flow 1.6.957, from its bundle and logs)

- Its Chromium audio service opens the mic **directly and input-only**:
  `IOWorkLoopInit: BuiltInMicrophoneDevice (BuiltInMicrophoneDevice)`. No
  aggregate, no voice processing of its own.
- When Safari's voice processing started, it closed and reopened the mic in
  **~150 ms** (21:56:54.800 → 21:56:54.953), and again ~200 ms after the page
  closed. It stayed **one utterance** throughout.
- Meeting participants in its meeting-notes mode come from a Core Audio process
  tap (`AudioHardwareCreateProcessTap`, `NSAudioCaptureUsageDescription`), and
  speaker labels come from reading the call app's UI through Accessibility.
  That is a separate feature and is **out of scope** here.

### 5. Our own voice processing was also tried and works, but is not the plan

`inputNode.setVoiceProcessingEnabled(true)` kept normal levels during Safari's
call (do not touch `mainMixerNode`, or `outputNode` initialization fails with
-10875; input format is 48 kHz 7 ch, voice in channel 0). It is kept as a
fallback only: it ducks other apps' audio while recording, has unmeasured
start latency, changes the signal the benchmark was measured on, and Wispr
shows it is unnecessary.

## Target behaviour

1. Capture opens the resolved input device directly, input-only. Output
   devices never affect capture.
2. A route change while recording (default input changed, channel count or
   sample rate changed, device died, callbacks stopped) rebinds to the right
   device within ~200 ms and **continues the same utterance** into the same
   buffer. The user sees nothing unless no input is available for more than
   ~2 s.
3. Any channel count works: capture takes channel 0 explicitly.
4. Quiet raw-array input is handled so the result and the silence notice stay
   correct (slice 4, decided by measurement).

## Slices

Verify with `xcodebuild` after every slice (AGENTS.md). The project is
`objectVersion = 56` without synchronized folders: every new Swift file has to
be added to `LocalDictation.xcodeproj/project.pbxproj` by hand (file
reference, build file, group, and the app or test target's Sources phase).

### Slice 1: channel handling in the converter (ships alone)

`LocalDictation/Services/Audio/AudioFormatConverter.swift`

- Stop relying on `AVAudioConverter.downmix` for more than two channels. For
  input with 3+ channels, copy channel 0 into a preallocated mono buffer at the
  input rate, then resample mono to 16 kHz with the existing converter. Mono
  and stereo keep their current path (`testStereoInputIsDownmixedToMono`
  must still pass).
- The mono scratch buffer is allocated in `init` from `maximumInputFrames`, so
  `convert` still does not allocate in the common case. Grow it only on the
  same "driver handed us more frames" path that already exists.
- `BenchmarkCorpus.swift:105` also builds this converter; confirm corpus
  results are unchanged.

Tests in `LocalDictationTests/AudioFormatConverterTests.swift`:

- 3-channel and 7-channel 48 kHz discrete buffers with a sine only in channel
  0: output is non-zero and matches the mono conversion of that channel within
  a small tolerance. This is the regression test for the exact-zero bug.
- Signal only in channels 1-2: output is silent (documents the channel-0
  choice).

After this slice alone, a call no longer produces `peak=0.000`, but the input is
still ~30 dB quiet and the engine still stops on route changes.

### Slice 2: input-only AUHAL capture, one device per utterance

New `LocalDictation/Services/Audio/HALInputCaptureService.swift` implementing
the existing `AudioCaptureService` protocol; swap it in at
`DictationCoordinator.swift:1822`. Keep `AVAudioEngineFragmentPlayer` as is
(playback is output-only and unaffected).

- Unit: `kAudioUnitType_Output` / `kAudioUnitSubType_HALOutput`.
  `kAudioOutputUnitProperty_EnableIO` input (element 1) = 1, output (element 0)
  = 0.
- Device: always set `kAudioOutputUnitProperty_CurrentDevice` explicitly, also
  for `.systemDefault` (resolve `kAudioHardwarePropertyDefaultInputDevice`
  through the existing `SystemAudioInput.resolve`). This is what removes the
  `CADefaultDeviceAggregate`.
- Format: read the hardware format on input scope element 1. Set the client
  format on output scope element 1 to Float32 non-interleaved, **1 channel**,
  device sample rate, with `kAudioOutputUnitProperty_ChannelMap = [0]` so the
  unit hands us device channel 0. Slice 1 stays as a second line of defence.
- Input callback (`kAudioOutputUnitProperty_SetInputCallback`) runs on the HAL
  IO thread: `AudioUnitRender` into a preallocated `AudioBufferList` sized from
  `kAudioUnitProperty_MaximumFramesPerSlice`, then the existing converter and
  `PCMCaptureSink.ingest`. No allocation, no logging, no main actor, no locks
  beyond the sink's existing `UnfairLock`.
- Stop: `AudioOutputUnitStop`, then drain the converter into the sink (same
  order as `AVAudioEngineCaptureService.stop` today), then uninitialize and
  dispose.
- Put the Core Audio calls behind a small protocol (for example
  `AudioHardware`: default input ID, input channel count, nominal rate, is
  alive, add/remove property listeners) so slice 3 tests run with a fake and
  never touch a microphone or permission dialog.
- Log once per start, with device name, rate and hardware channel count.

Check after this slice: during a dictation, coreaudiod logs
`IOWorkLoopInit: BuiltInMicrophoneDevice (BuiltInMicrophoneDevice)` for
Witness, not `CADefaultDeviceAggregate-<pid>`. Compare start latency
(`State ready -> starting` to `State starting -> recording` in the Witness log;
today it is 0.5 to 1.1 s).

Leave `AVAudioEngineCaptureService` in the tree until slice 3 is verified on
hardware, then delete it and move its tests.

### Slice 3: rebind mid-utterance without ending it

Split the running session into the utterance (sink, VAD, owned for the whole
recording) and the **input segment** (unit, device ID, hardware format,
converter, owned per device binding).

Triggers, observed only while recording, on a private serial queue (never do
work on the Core Audio listener thread):

- `kAudioHardwarePropertyDefaultInputDevice` changed, when the selection is
  `.systemDefault`.
- On the bound device: `kAudioDevicePropertyStreamConfiguration` (input scope)
  channel count changed (the Safari call case),
  `kAudioDevicePropertyNominalSampleRate` changed,
  `kAudioDevicePropertyDeviceIsAlive` became 0.
- `kAudioHardwarePropertyDevices` changed, for `.device(uid)` and `.builtIn`
  selections whose device disappeared.
- Watchdog: no input callback for 500 ms while running, or `AudioUnitRender`
  returning an error.

Rebind: debounce 150 ms (Bluetooth and voice-processing switches arrive as
bursts of dozens of notifications within milliseconds), stop the old unit,
drain its converter into the sink, resolve the device again, build a new
segment, start it. Do not insert synthetic silence for the gap; log it.

Policy, as a pure function so it is unit-testable (for example
`InputRoutePolicy.action(for:event:current:selection:devices:)` returning
`.keep`, `.rebind(deviceID)`, `.interrupt(AudioCaptureError)`):

- `.systemDefault` follows the new default mid-utterance (that is what the
  user asked for and what Wispr does).
- `.device(uid)` or `.builtIn` whose device vanished: fall back through the
  existing `SystemAudioInput.resolve` order and continue. If the preferred
  device comes back mid-utterance, do not switch back until the next
  utterance, which avoids flapping.
- Same device, only the format changed: rebind to the same device.
- Retry budget like today's (4 attempts within 2 s). No resolvable input for
  more than 2 s: `.interrupt(.noInputDevice)`, which the coordinator already
  turns into "finished, transcribed, delivered, reason said afterwards".
- `.inputDeviceChanged` is no longer emitted for a successful rebind.

Log each rebind at notice level: reason, from/to device, new rate and
channels, gap in ms. Add a rebind count to the utterance diagnostics so a
report shows it. Device names are not content.

Tests:

- Policy table tests for every trigger × selection above, and the retry budget
  with an injected clock.
- Debounce: a burst of 30 events within 50 ms produces one rebind.
- Splice: frames from a 48 kHz 1-channel segment, then a 48 kHz 3-channel
  segment, land in one sink; frame count equals the sum of both converted
  segments, and VAD state is not reset between them.
- Coordinator: a route change that rebinds does not end the recording and
  shows no notice. `CaptureInterruptionTests` keeps covering the
  `.noInputDevice` path; its `.inputDeviceChanged` cases are rewritten or
  removed, since that error no longer ends a recording on its own.
  `FakeAudioCaptureService` in `LocalDictationTests/Support/TestDoubles.swift`
  may need a way to report a rebind.
- `CapturePrivacyTests.swift:210-234` test
  `AVAudioEngineCaptureService.actionAfterConfigurationChange`: move them onto
  the new policy.

### Slice 4: quiet raw-array input (measure first)

During a call the raw channel is ~30 dB below normal. Two things depend on
level:

- The VAD: `speechThreshold` is 0.02 RMS (about -34 dBFS). `speechStart` gates
  the silence notice (`DictationCoordinator.silence(for:)`), so a quiet but
  correctly transcribed utterance is fine, while an empty result would be
  misreported as "nothing heard".
- Recognition: unknown for WhisperKit at -55 dBFS. Wispr transcribed the same
  situation correctly, but it is a different engine.

Measure before choosing: run the benchmark corpus attenuated by 30 dB against
the normal corpus, for all four verified languages. Decision rule:

- No measurable loss: leave recognition alone. Recompute voice activity for
  the silence notice on a gain-normalized copy of the finished utterance, so
  the notice stays truthful. Nothing changes in the real-time path.
- Measurable loss: normalize the finished utterance before transcription
  (peak to about -1 dBFS, gain capped at +40 dB, off the real-time path,
  deterministic and unit-tested), and derive the silence notice from the same
  normalized samples. Fragment replay then plays the normalized audio, which
  is acceptable.

Either way, do not lower the global VAD threshold: it would make every
normal-mic dictation noisier.

### Measured 2026-09-29

WhisperKit large-v3 turbo over the `tts-smoke` corpus, 24 samples, six per
verified language, each scored twice: at the corpus level and 30 dB below it.
Full table in `Benchmark/report-quiet-whisperkit.md`.

| Language | Samples | WER normal | WER quiet | Δ WER | Δ CER |
| --- | ---: | ---: | ---: | ---: | ---: |
| English | 6 | 21.4% | 19.0% | -2.4 pp | +0.0 pp |
| German | 6 | 7.3% | 7.3% | +0.0 pp | +0.0 pp |
| Russian | 6 | 15.2% | 15.2% | +0.0 pp | +0.0 pp |
| Ukrainian | 6 | 18.2% | 21.2% | +3.0 pp | +2.0 pp |
| **Overall** | 24 | **15.4%** | **15.4%** | **+0.0 pp** | +0.5 pp |

German and Russian are identical to the digit. English and Ukrainian move in
opposite directions by about one word each, which on six samples per language is
sampling noise, not a result: nothing here separates a difference smaller than
roughly 5 pp. What the table does support is the decision it was run for —
there is no measurable loss at 30 dB.

Two limits worth stating. The corpus is synthesized speech, so attenuation
models the *level* of a raw microphone array and not its character: the real
channel has its own noise floor and no Apple processing. And six samples per
language is a small sample.

So: recognition is left alone. What changed is only the silence notice, in
`NormalizedVoiceActivity`. It recomputes voice activity once, off the real-time
path, on a copy of the finished utterance with its peak normalized to -1 dBFS,
and the notice uses that answer instead of the live detector's.

It refuses to answer when the gain needed exceeds +40 dB, and the caller then
keeps the live answer. That guard is the point rather than a detail: the raw
array was measured at -50 to -63 dBFS RMS while speaking and -65 to -85 dBFS
while silent, so normalizing without a cap would lift a muted microphone's noise
floor past the speech threshold and tell someone their words were not recognized
when their microphone was off. Past the cap the loudest moment is still the
noise floor, and the conservative answer stands.

### Slice 5: docs and hardware verification

- `docs/REFINEMENTS.md`, section "A changed microphone no longer takes the
  sentence with it": a route change now continues the utterance; only a
  vanished input ends it.
- `docs/PHASE_4_COMPATIBILITY.md`: record the call case as closed.
- `docs/ARCHITECTURE.md`, audio section: direct AUHAL, segments, policy.

Hardware checklist (use the unified log; see the recipe below):

1. Dictate before opening Meet in Safari, open the pre-join page mid-sentence,
   keep talking, close it, keep talking. Expect one utterance, one or two
   rebinds logged, correct text, no notice.
2. Dictate while the Meet page is already open. Expect `1 ch` client format
   from a `3 ch` device, non-silent peak, correct text.
3. Same in Chrome (never tested; Chrome may not use Apple voice processing at
   all).
4. With `systemDefault`: connect and disconnect AirPods mid-sentence. Expect a
   rebind to the new default and back, one utterance.
5. With `builtIn` selected and AirPods connected: capture stays on the
   built-in mic, and AirPods do not switch to the headset profile because of
   Witness.
6. Start latency compared with the numbers noted in slice 2.
7. coreaudiod shows no `CADefaultDeviceAggregate-<Witness pid>` during
   dictation.

## Verified on hardware 2026-09-30

Author's MacBook Pro, macOS 26.6.2, the build from this branch. Log lines are
quoted as they appeared.

**2. Dictating with the Meet page already open.** The microphone reports the raw
array and capture takes channel 0:

```
Capture started: MacBook Pro Microphone, device 48000 Hz 3 ch, client 16000 Hz mono from channel 0
Capture finished: 64853 frames, dropped 0, rebinds 0
RU+EN+UK decoded as ru (confident) -> 6 tokens
```

Before this branch the same situation logged `3 ch` and then `peak=0.000`.

**1. The Meet page opening mid-sentence.** One utterance across the change:

```
13:43:57  Capture started: device 48000 Hz 1 ch
13:44:13  Input rebound (boundDeviceFormatChanged): -> 48000 Hz 3 ch
13:44:47  Capture finished: 48.83 s, 781312 frames, dropped 0, rebinds 1
          -> 58 tokens
```

One rebind rather than two is correct here: Safari held voice processing until
13:44:49, two seconds *after* the press ended, so the device never went back to
one channel while recording.

**4. AirPods connecting and disconnecting mid-sentence, `systemDefault`.** The
first hardware exercise of following the default onto a different device, and of
a sample rate changing mid-utterance:

```
14:40:49  Capture started: MacBook Pro Microphone, device 48000 Hz 1 ch
14:41:01  Input rebound (defaultInputChanged): MacBook Pro Microphone -> AirPods, 24000 Hz 1 ch, gap 281 ms
14:41:14  Input rebound (defaultInputChanged): AirPods -> MacBook Pro Microphone, 48000 Hz 1 ch, gap 139 ms
14:41:21  Capture finished: 31.42 s, 502784 frames, dropped 0, rebinds 2
          -> 60 tokens
```

**5. `builtIn` selected, AirPods connected.** The system had genuinely moved on:
`system_profiler` reports `Sweetheart's AirPods #2 ... coreaudio_default_audio_input_device`
while capture opens the other device.

```
14:43:31  AirPods connect, profile "airpods noise suppression studio"
14:43:34  IOWorkLoopInit: BuiltInMicrophoneDevice (BuiltInMicrophoneDevice)
14:43:34  Capture started: MacBook Pro Microphone, device 48000 Hz 1 ch
14:43:46  Capture finished: 11.65 s, 186368 frames, dropped 0, rebinds 0
          -> 19 tokens
```

No `Input rebound`, no `Preferred microphone unavailable`, and no input context
was ever opened on the AirPods, so nothing dragged them into the headset profile.

Tested with the AirPods already connected before the press. Connecting them
*during* a `builtIn` dictation, so the policy answers `.keep` to a live
`defaultInputChanged`, is covered by `testANamedDeviceIgnoresTheDefaultChanging`
and not yet on hardware.

**6. Start latency.** `State ready -> starting` to `State starting -> recording`,
three presses: 175 ms, 169 ms, 186 ms. The aggregate build it replaces was
0.5 to 1.1 s.

**7. No aggregate.** Zero occurrences of `CADefaultDeviceAggregate-<pid>` across
every session; coreaudiod logs
`IOWorkLoopInit: BuiltInMicrophoneDevice (BuiltInMicrophoneDevice)`.

### What a rebind still costs

The Meet run recorded 48.83 s of a 49.64 s press: **0.81 s of speech is missing**
across one route change. The sentence survives, the words inside that gap do not.
Broken down from the log:

```
13:44:12.826  the device stops delivering frames
              ~469 ms of notifications, each restarting the debounce
13:44:13.295  last notification of the burst
              +150 ms debounce
13:44:13.445  rebind starts
              +192 ms tearing down the old unit and building the new one
13:44:13.637  the new segment is running
```

Only the last 192 ms is ours. The rest is detection plus the debounce, and most
of that is the debouncer restarting its quiet period on every event in a burst
that lasted 469 ms.

A cap — fire at most N ms after the *first* event of a burst, however long the
burst continues — would cut it. Not done: rebinding mid-burst can bind to an
intermediate state of the device and cost a second rebind immediately after, and
there is no measurement yet saying which is cheaper. The number above is what
that decision should be made against.

The logged `gap` was itself wrong until 2026-09-30: it timed our own teardown
rather than the silence, and reported 192 ms where 810 ms had passed. It now runs
from the last frame that arrived.

### Still open

3 (Chrome), which may well be a negative result: Chrome may not use Apple voice
processing at all, in which case the device stays at one channel and there is
nothing to rebind through.

## Open: a headset shared with a phone (reported 2026-09-30)

Reported by the user on 2026-10-01 about the evening before: AirPods paired to
both this Mac and the phone, music playing from the phone, and Witness does not
pick up the microphone at all. Wispr Flow in the same situation stops the music
and dictates normally.

This is a different failure from everything above. There the microphone was open
and the signal was wrong; here another host owns the headset, and the question is
what makes it hand the microphone over.

### What the log says about the incident: nothing

Checked on 2026-10-01 over the whole retained window. The Witness audio category
has no entry from that session: the running instance (pid 61288, 17:00 to 18:44)
left only `transcription` lines in the persisted store, and every
`No microphone input device is available` burst that day belongs to a test run,
not to a press. So the failure mode is not established yet, and the three
candidates below are still candidates:

1. The AirPods report input streams with zero channels while the phone holds the
   link, `configure` reads `0 ch` and start fails with `unsupportedInputFormat`.
2. Frames arrive, at the noise floor, because the headset answered the Mac
   without switching its microphone over. The user then gets "nothing heard".
3. No callback arrives, the watchdog fires `inputStalled` four times inside its
   2 s window and the utterance ends with `engineStartFailed`.

### The mechanism, and why this may be ours rather than Apple's

Opening the input half of a Bluetooth device is the whole claim capture makes
today. Slice 2 deliberately removed the other half: `AVAudioEngine` used to
record through `CADefaultDeviceAggregate`, whose IO work loop is the default
**output** device, so recording used to claim an output too. For a headset that
two hosts are competing for, the output claim is exactly what a call makes and
what media playback makes, and it may be what the arbitration actually keys on.
If so, the aggregate we were right to remove was carrying this for free, and the
regression arrived with 0da260c.

Worth asking the user and cheap to answer: did dictation with music from the
phone work before 0.6.8?

### The probe

`Tools/probe_bluetooth_input.swift` answers both halves of the question in one
run of about a minute, and needs the phone, the AirPods and music:

```bash
swift Tools/probe_bluetooth_input.swift --device AirPods
```

Phase 0 records the built-in microphone as a control, because the probe's
microphone permission belongs to the terminal and zeros everywhere would
otherwise read as a Bluetooth result. Phase A opens the headset input only, the
way capture does today. Phase B adds a silent output on the same device. Phase C
opens the device with voice processing, the way a call does. Each phase reports
callbacks, first-callback latency, peak and RMS, and re-reads the device's
channels and rate while it runs; the operator notes after each phase whether the
music is still playing.

### Decision rule

- Phase A already hears speech: the failure is not the claim, and the log from a
  real press decides between the three candidates above.
- Phase B stops the music and hears speech: capture keeps a silent output claim
  open on the bound device for the duration of a recording, and only for
  Bluetooth transports. It is a second audio unit beside the segment's, owned by
  the same queue, torn down with it, and it leaves the signal path and the
  benchmark untouched.
- Only phase C works: voice processing becomes the path for Bluetooth inputs.
  That is a bigger change than it looks, because it ducks other apps' audio,
  changes the signal the benchmark was measured on, and would have to be
  measured again per language.
- Nothing works: the next experiment is making the headset the default output
  for the duration of a recording, which mutates a system setting and needs its
  own decision.

Either way the start path has to stop reporting this as "nothing heard": a
Bluetooth device delivering frames at the noise floor is a different thing to
say, and the user can act on it.

## Investigation recipe

```bash
/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "com.witnessmac.Witness" OR process == "coreaudiod"'
```

Useful coreaudiod lines: `VPAUAggregateAudioDevice` (someone started voice
processing), `IOWorkLoopInit: <device> (<context>)` (which device a client
really runs on), `PublishRecordingClientInfo: Report client <pid> running`
(when a process has the mic open). Use the full `/usr/bin/log` path; `log` is
shadowed in the user's shell.

## Out of scope

- Capturing other meeting participants (Core Audio process tap) and speaker
  labels. Product decision and a separate phase.
- Our own voice processing, unless slice 4 shows the raw path cannot be made
  to work.
- Keeping the microphone warm between utterances.
