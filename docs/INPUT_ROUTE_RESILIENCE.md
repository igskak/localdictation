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
