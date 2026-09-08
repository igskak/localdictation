# Refinements — the gaps between what the app promised and what it did

Not a phase. Every item here came from one of two places: a line in this
project's own scope that was never built, or an entry in
`docs/PHASE_4_COMPATIBILITY.md`'s **Open** list that had been sitting there
since it was written. Nothing here required a decision that was not already
recorded somewhere in these documents.

## The app now answers a press that produced nothing

An empty result inserted nothing, needed no review, and returned the app to
`.ready`. So the user, who had just spoken a whole sentence, read silence — and
silence from a dictation app is indistinguishable from a hotkey that did not
work. `docs/PHASE_4_COMPATIBILITY.md` recorded two real utterances of 8.8 s and
10.1 s that came back with `0 tokens` on a development Mac and listed the
consequence under *Ways the text can fail to arrive*.

It says which of the two silences it was, because they have different answers.

| What happened | How the app knows | What it says |
| --- | --- | --- |
| The microphone was open and nothing reached speech level | The detector never set `speechStart` | Names the input device and the peak level |
| Speech was heard and the engine returned no words | `speechStart` is set, the result is empty | Names the language profile it was asked in |

The second one is worth the extra case on its own: dictating German on a Russian
profile is the cheapest way to get nothing back, and the profile is one line
away in the same menu.

The notice is the counterpart of the attention indicator and behaves like it. It
lights the menu bar symbol, it appears in the panel a clipboard fallback already
uses — where the user is looking, rather than in a menu they have no reason to
open — and it clears when it is dismissed or when the next dictation starts. A
transcription *failure* keeps its own sentence: two explanations for one press is
one more than the user can act on.

## A refusal names the application responsible

Secure input is one process-wide flag. While it is on, every dictation
everywhere is refused, which `docs/PHASE_4_COMPATIBILITY.md` calls the worst
failure mode in the insertion path — a whole app that has stopped working reads
as broken rather than as careful. What the user was told was "an application has
secure input enabled": a true description of a problem, said to someone with
thirty applications open, with no action attached to it.

The app now asks the window server which process holds the flag and says the
name, with the two things that clear it. `CGSessionCopyCurrentDictionary()` is
public CoreGraphics; the key naming the owner is not a declared constant, so
every step is optional and the whole thing degrades to the old sentence. A
missing key costs the user a name, not an answer.

Secure input moved behind `SecureInputSource` at the same time. The real flag can
only be raised by focusing a password field or by an application that leaks it,
so the refusal a user is most likely to meet was the one behaviour in the
insertion path with no test at all.

The menu says it too, before a dictation is spent finding out. A refusal
arrives after a whole recording and a transcription, which is a long way to
travel to be told the answer was knowable before the key was pressed — and the
menu is the first place someone looks when an app has stopped working. The
warning sits above the Accessibility offer, because while secure input is on,
granting Accessibility changes nothing, and an offer to fix the wrong thing is
how someone spends ten minutes in System Settings and still cannot dictate.

**The stuck-flag decision is still open.** The refusal is deliberate and protects
a password field. What to do about an application that exits leaving the flag on
is a separate question, and naming the holder does not answer it — it only makes
the state legible while it lasts.

## A changed microphone no longer takes the sentence with it

`AVAudioEngineConfigurationChange` fires when AirPods connect, when a dock is
plugged in, when a headset goes to sleep. The app was already listening. What it
did was drop the recording, discard the captured audio, and land in `.failed`
with "Recording stopped" and a Try again button — thirty seconds of speech, gone.

`docs/PHASE_6.md` spends a section on the rule this breaks:

> A trial that runs out mid-utterance **never takes the sentence with it.**

A device change is the same situation with a different cause. The recording now
ends where the device went away, but it ends the way a released key ends it:
finished, transcribed, delivered, and the reason said afterwards rather than
instead. The notice carries both halves, because "recording stopped" alone reads
as "your dictation was lost" and sends the user to redictate text that is already
in their document.

It also outranks the empty-result notice. A device unplugged mid-sentence
explains an empty result; "nothing was heard" would send someone to check a
microphone that was working until it left.

An interruption arriving before the engine has opened is still a failure —
nothing was captured, so there is nothing to save and the failure is the whole
story.

## Both recording modes exist

`docs/PRODUCT_SCOPE.md` has listed "global push-to-talk **and** toggle recording
modes" in the MVP since the first draft. Only the first was built.

They are not two preferences about one thing. Push-to-talk is a key held for the
length of a sentence; toggle is two presses around a paragraph, and nobody holds
a key for four minutes.

The state machine needed no change. A toggle stop is routed to the same
`.hotkeyReleased` the key release used to send, so `.starting`, `.recording`, and
`.finishing` behave exactly as they did — including a second press arriving
before the engine has finished opening, which cancels rather than being
swallowed. What did change is the instruction: telling a toggle-mode user to
release the key is telling them to do the one thing that will not work.

## The shortcut can be changed

⌥Space was a constant. On a Mac where something else already owns it, the app was
unusable and there was no way out from inside it.

Carbon offers no way to ask whether a combination is free — the only way to find
out is to register it — so the change path is built around failing. The working
shortcut goes back the instant a new one is refused, and the user is left with a
working app and a sentence rather than a shortcut that silently stopped existing.

Two details are load-bearing:

- **The current shortcut is unregistered while the user is choosing.** A
  registered Carbon hotkey consumes its combination before any window sees it, so
  leaving it in place would mean the one combination the user cannot press while
  choosing is the one they already have — and pressing it would start recording
  into the settings window. The settings window closing mid-capture puts it back,
  which is the path that matters most: it would otherwise leave the app with no
  shortcut and nothing on screen saying so.
- **A combination with no modifier is refused before it reaches the system.**
  Registering a bare key takes it away from every application on the Mac,
  including this app's own text fields.

The label is stored with the binding rather than derived from the key code,
because a key code names a position: key 12 is `Q` on QWERTY, `A` on AZERTY, and
an apostrophe on Dvorak. It comes from the event that recorded it, where the
system has already applied the user's layout.

## The app opens at login

An app with no Dock icon is one nobody remembers to open, and a hotkey belonging
to an app that is not running reads as a broken hotkey.

Four states rather than a boolean, because macOS gives four answers and two of
them cannot be acted on from inside the app. `requiresApproval` means the user
switched it off under Login Items and only they can switch it back on. A build
running from Xcode is the other: macOS will not make a login item out of an app
in DerivedData, and "operation not permitted" on its own sends people looking for
a permission that does not exist, so it gets its own sentence.

## Settings reach disk

A shortcut that reverts to ⌥Space on every launch is not a configurable
shortcut, and a language profile that resets is a four-language product asking
the same question every morning. So there is a third file in Application Support
beside the dictionary and the licensing record.

`preferences.json` holds six fields: the shortcut's key code, modifier mask, and
label; the recording mode; the language profile; and whether insertion is
automatic. A test asserts that list, the same way one asserts `license.json`'s —
a persisted payload is a promise about what the app keeps, and a promise nobody
checks is one that drifts.

It is a file rather than a `UserDefaults` domain on purpose. Everything this app
writes belongs in one directory the user can open, and it is the same argument
`docs/PHASE_6.md` makes for keeping the licensing record readable.

A settings file that cannot be read is a first run, not a failure. Refusing to
dictate over a corrupt preference would be the app treating its own settings as
more important than the thing it exists to do. A stored binding with no modifier
— which can only come from someone editing the file by hand — is ignored rather
than registered.

## What a test now covers that it did not

- Sixty dictations, quiet and flagged, never hold more than one utterance's
  audio. This is the structural half of the "ten minutes of repeated short
  recordings without memory growth" item that `docs/PHASE_3_VERIFICATION.md` has
  carried as unverified since Phase 3 added the retained buffer. **The soak
  itself still needs a person and a microphone** — what a test can settle is
  where a leak would come from, not how much memory ten minutes costs.
- The secure-input refusal, in both the named and unnamed cases.
- A device change mid-recording, including that the text still arrives and that
  the capture is stopped exactly once.
- Every path through changing a shortcut, including the two refusals and the
  settings window closing mid-capture.
- The settings window and the menu rendered through real AppKit layout, in the
  states where the new rows appear. `ReviewPanelControllerTests` exists because
  a SwiftUI view crashed the app the first time it appeared while every unit
  test passed, and three new sections is exactly the kind of thing that repeats
  it.

## One test was wrong rather than one behaviour

`CapturePrivacyTests.testNormalCapturePathWritesNothingToDisk` compared an exact
listing of the shared temporary directory before and after a capture. The test
target runs its classes in parallel processes, and the classes covering the
glossary, the licensing record, and the issuer tool create throwaway directories
in that same place while it runs. It passed only as long as the scheduling never
interleaved; adding a class to the suite was enough to lose the race, and the
failure reported a write the capture path had not made.

The claim is unchanged and still has teeth. Directories nothing else writes to
are still compared entry for entry. The shared temporary directory is now
compared by attribution: the only file this app ever writes from an utterance is
a WAV, and no sibling test writes audio, so a stray recording is still caught
while another test's throwaway home is not.

## A locked Mac no longer opens the microphone

`.hotkeyPressed` on a locked Mac returns `.locked` from the state machine — the
lock is what the press discovers, which is the right answer. What was wrong was
downstream: `DictationCoordinator.apply` reports any computed state as
`.transitioned`, and `.locked -> .locked` therefore read as success. The guard
at the top of `beginCapture` let it through, and the microphone opened on a Mac
that is not allowed to record at all. It then stayed open: `.captureStarted` and
`.hotkeyReleased` are both refused in `.locked`, so nothing on the ending path
ever ran.

For a product whose promise is that speech does not leave the Mac, a recording
indicator lit for someone who is not even a customer is the worst shape a defect
can take here.

The precondition is now checked where preconditions belong — before the
microphone, beside the state rather than inside it, which is the same
arrangement Phase 6 chose for the lock itself. The press is still applied, so a
lock that arrives mid-utterance still leaves the words in flight alone and the
press that lands during one is still refused.

`testALockedMacNeverOpensTheMicrophone` did not catch this, and could not: the
capture starts inside a `Task`, and the assertion ran on the line after the
press, before the microphone would have opened. It now waits, and asserts the
stop count as well — a start that is never stopped is the part that costs a
user something. Removing the fix fails it.

## The press is where the price is named

The lock used to be passive: the hotkey stopped working, the explanation sat in
the menu bar window, and the two offers sat in Settings. Somebody whose trial
ended could go a week assuming the app had broken.

`PaywallWindowController` shows the offers when a press finds the Mac locked.
Not on a schedule and not at launch — a person pressing the dictation key is
saying they want the product right now, which is the moment a price is an answer
rather than an interruption. It does not activate the app: taking focus from the
document someone is writing in, to show them a price, is how a utility gets
uninstalled. Floating and ordered front is enough.

`paywall_shown` moved with it. It used to be sent when the Mac became locked,
which is a different and much commoner fact — a Mac can lock at launch, in the
background, with nobody looking. It is now sent by the window that draws the
price, once per appearance, so the number means what its name says. Nothing was
added to the enumerated events, and the funnel a full run produces is unchanged.

## Still open, and still needing a decision

These were on the **Open** list before this work and remain there, because each
one is a product decision rather than a defect:

- **Witness itself in front.** Dictating with the menu bar panel or
  Settings open captures no target, so the text goes to the clipboard.
  Remembering the last application would insert where the user expects, at the
  cost of either activating another application — a visible window switch — or
  restricting the insertion to a direct Accessibility write, which is not
  available in the applications that need the fallback most.
- **System-wide secure input stuck on.** Now legible, still not resolved.
- **A terminal, and a modal editor inside one.** ⌘V arrives as keystrokes, and in
  `vim`'s normal mode keystrokes are commands.
- **A target Accessibility cannot see into.** Remote desktops, virtual machine
  guests, X11, some Java and Qt applications. This is the honest limit of the
  approach.
- **A clipboard manager.** Every paste-path insertion puts the dictation on the
  pasteboard for a moment, and a manager keeps it.

## A blocked ⌘V says it is blocked

The app posted a synthetic ⌘V, watched the field, saw nothing change, and told
the user that the application would not accept the text directly. For a whole
session that sentence was false in every particular: the window server was
dropping the key event before it left this Mac, and the target application was
never asked.

The two permissions look like one from inside the process and are not.
`AXIsProcessTrusted()` is answered once at launch and holds for the life of the
process; the right to *synthesize* an event is checked on every post against the
signature the application has now. Replace the application — a rebuild, an
update — and the grant recorded against the old signature stops applying to the
new one while the checkbox in System Settings stays ticked. `CGEventPost`
returns `Void`, so nothing about that reaches the app.

`CGPreflightPostEventAccess()` is the same question asked where the answer is
still useful. It is asked twice, on purpose: in `InsertionPolicy`, where a paste
is chosen, and again at the top of `AXTextInsertionService.paste(_:into:)`,
because the Electron path arrives there through a swallowed direct write rather
than through the policy — and the application that reaches the paste by the
fallback was the one getting the wrong sentence.

The preflight is the checking variant and not `CGRequestPostEventAccess()`,
which raises a system prompt. Raising one mid-insertion would interrupt the
user in the second they are waiting for their sentence to appear. The refusal
names the setting instead, and the text stays on the pasteboard rather than
being restored away: until the permission is back, the user's own ⌘V is the
only way in.

## The first run stops making the user find things

The first stranger to install a build produced two questions inside a minute,
and neither of them was about dictation. *Can it ask for the permissions at
launch, like everything else does, instead of making me click the icon and press
allow, allow?* And: *it was not obvious that a language model had started
downloading.*

Both are the same defect wearing different clothes. Everything the app needed
before it could work was reachable, correct, and behind an icon in the menu bar
that a new user has no reason to open. A utility with no Dock icon and no window
cannot afford anything to be *findable*: whatever is not in front of the user on
the first run does not exist.

### Both permissions are asked for on the first run

`FirstRunReadyView` — the screen that follows the language question — now asks
macOS for the microphone and for Accessibility as it appears, one after the
other, with the reason for each visible behind the system dialog.

It happens there rather than in `applicationDidFinishLaunching` on purpose. A
prompt raised with nothing on screen is a prompt with no context: the user sees
the name of an app they installed thirty seconds ago and a request to control
their computer, and the only honest thing they can do is deny it. The window is
already up, already activated, and already explaining what each permission buys
— so the dialog lands on top of its own justification.

The two are not symmetrical and the screen says so. The microphone is granted
from inside the dialog, so that row is usually ticked by the time anybody reads
it. Accessibility is granted in System Settings, out of band, and the prompt
only offers to open them; the app was already watching for the grant every two
seconds while it is missing, so the row ticks itself without anyone coming back
to press a re-check. Neither ask blocks anything. Denying both leaves a working
first run, minus insertion, exactly as before.

### The app fetches the speech model itself

`docs/PHASE_2.md` said the download is an explicit user action, never automatic
at launch, on the reasoning that an application does not help itself to six
hundred megabytes of somebody's connection. That reasoning survived until a
real installation, and then it did not.

The weights are not a feature. Nothing in the product recognizes a single word
without them, so the button was not offering a choice — it was a step, in a
window nobody had been told to open, between a fresh install and an app that
appears to do nothing at all. A choice with one correct answer is a chore.

So `prepareModelAtLaunch()` now downloads as well as loads. What the app owes in
exchange is that the fetch is never silent:

- the menu bar icon is a download arrow while it runs, and the menu says which
  phase it is in and how far the download has got, with a real percentage;
- the first-run screen shows the same progress, and says it keeps going after
  the window is closed;
- `docs/PRIVACY.md` moved the row out of "because you pressed something" and
  says what to do about it — quitting before it finishes — rather than quietly
  reclassifying it.

A launch that finds the engine `.failed` — no Application Support, no disk —
still does nothing on its own. That is a broken installation rather than a
missing download, and retrying it in a loop nobody asked for says nothing new.

### A press during the wait is answered

The press that arrives before the model does is the commonest thing a new user
will do, because pressing the key is the entire product. Before this it did one
of two things, and both read as an app that does not work: it recorded into the
load — the recording joined it and the text arrived minutes later, long after
the user had moved on and often into a different application — or it failed with
a sentence about a button they had never seen.

Now nothing is recorded, the state machine is not touched at all, and
`SpeechModelNotice` says the three things the user actually needs: this happens
once, roughly how long it takes, and that the app will say when it is over. It
appears in the panel a clipboard fallback already uses — where the user is
looking — and it keeps its promise: whoever pressed during the wait gets one
more sentence when the model lands, and whoever did not gets nothing, because a
panel opening over somebody's document to report that nothing is wrong is noise.

One press is still served rather than answered, and the exception is the older
decision rather than an oversight. Reading weights that are already on disk
takes about nine seconds; a recording made during that load is held and
transcribed the moment it ends, and `StatusPresentation` has named that wait
since Phase 2. Refusing it would throw away words the user had already said in
order to save them nine seconds. A download and a first-ever Core ML
compilation are the other kind of wait — minutes — and text arriving minutes
late lands in whatever application the user has moved on to, which is worse than
not arriving. `TranscriptionModelState.isLongWait` is where the two are told
apart, once, for every place that acts on the difference.

A press when the weights are missing and nothing is fetching them — a launch
with no network, a fetch that failed — starts the fetch rather than sending the
user to look for a button. The button stays in the menu for that case, renamed
from *Prepare speech model…* to *Get the speech model*: nobody has to prepare
anything any more, and the only person who sees it is someone whose download did
not happen.

## Three events about the trial now leave the Mac

`docs/PHASE_8_DECISIONS.md` D7 shipped the first release transmitting nothing,
and called itself "the one item that is safe to leave". It was, right up to the
first question that needed it.

That question is whether the wall is where people give up. `docs/PRODUCT_SCOPE.md`
has said since the first draft that the download is never gated and that
activation is required at the end of an ungated window. Whether that window
costs anything is not knowable from this side of the screen, and every event
that would answer it was being built, envelope and all, and written to a log on
the user's own Mac where nobody would ever read it. (The next entry moves that
window from five dictations to three days — a change argued from the shape of
the product rather than from data, because this measurement had not run yet.)

So three of the ten are now sent, and seven are not:

| Sent | Why this one |
| --- | --- |
| `trial_started` | The denominator. Someone who never dictated is not somebody who gave up |
| `paywall_shown` | The refusal, with which of the four reasons caused it |
| `activation_requested` | The way out being taken |

The other seven stay local. Not because they are more sensitive — all ten carry
the same five fields — but because `activation_succeeded` and `license_accepted`
are already known to the service from the calls that cause them, and a list that
grows to "all of them" is a list nobody checks. `TelemetryEvent.transmitted` is
the list, `Service/src/events.js` refuses anything outside it, and a test on each
side asserts the same three names. Two allowlists rather than one, because a
build that starts sending a fourth event is a build nobody can update.

**On by default, and said out loud.** This is the one switch in the product that
defaults to sending something, and the reason is that the alternative does not
work: a count of who gives up, taken only from people who opted in, is a count
of people who did not give up. That is not a good enough reason to be quiet
about, so the first-run screen carries the sentence, Settings → Privacy carries
the switch, and `docs/PRIVACY.md` prints the body byte for byte — four fields,
five for `paywall_shown`, and a test that fails when a sixth appears.

The transport is deliberately the smallest thing that works. One attempt, no
queue: a retry queue would be a fourth file this app writes to disk, and the
privacy policy enumerates three. No reply is read, nothing blocks a press, and a
plain-HTTP endpoint makes it report itself unconfigured rather than send in the
clear — the same rule `HTTPActivationBackend` has, for the same reason.

Rows are kept ninety days and swept behind the answer, the way the rate counters
already were. Retention that depends on somebody remembering to run something is
not retention.

## The wall moved from the fifth dictation to the third day

`docs/PRODUCT_SCOPE.md` had said since its first draft that activation is
required after five dictations or 24 hours, whichever comes first. The count is
what was wrong with it. A dictation in this product is a whole utterance, so a
person actually using it spent all five in one conversation and met the wall
about two minutes in — before they had formed any opinion worth trading an email
address for. The 24-hour half almost never fired, because nobody gets to the
second day with four dictations spent.

An email at that moment is asked for at the worst point on the curve: the
product has been demonstrated but not yet been useful. So the window is now
three days from the first successful dictation, and how much is said inside them
is nobody's business.

There is deliberately no count any more. Two ways to end one window meant two
sentences to write, two thresholds to warn on, and a countdown in the menu bar
that measured presses while the user was thinking in days. `UsageRecord` loses
`successfulDictations` with it — a field that is written, persisted and read by
nobody is worse than one that is not there, and this record's whole documented
virtue is that it is small enough to read in one breath.

**The trial itself became ten days**, so that three ungated plus ten activated
is thirteen — close to the fortnight the scope always meant. That number now
lives in two languages: `EntitlementPolicy.trialDuration` in the app, which is
what lets the app *name* the expiry date before the user hands over an address,
and `TRIAL_SECONDS` in `Service/src/activate.js`, which is what actually goes in
the key. An app predicting fourteen while the service issues ten lies at the
exact moment it is asking to be trusted, so
`EntitlementPolicyTests.testTheAppAndTheServiceAgreeOnHowLongATrialIs` reads the
service's own source and fails when they drift.

### Two things this exposed rather than introduced

**A sentence that was already false.** `LicensePresentation.activationSucceeded`
told an activated user "the trial runs for fourteen days from your first
dictation". It never did: the service issues from the moment of activation and
does not know the date of the first dictation — the request has two fields and
`docs/PHASE_8.md` froze it that way. While the ungated window was 24 hours the
gap was too small to notice. At three days it is a sentence the user can catch
out, so it now says what happens.

**A lock that answered the wrong question.** `EntitlementPolicy` checked "have
fourteen days passed since the first dictation" *before* the ungated deadline,
which was unreachable while the window was 24 hours and reachable the moment it
became three days. Somebody who dictated once, never activated, and came back a
fortnight later was told their trial had expired and shown the offers. They had
never had a trial — and the service would still issue them one, because neither
their address nor their Mac has taken it. That branch is gone: without a key
there is nothing to expire, so an unactivated record is always asked to
activate.

### What the notice does now

The ungated window is three days and the trial's own warning threshold is three
days, so reusing it would have put the countdown on screen from the first
minute — against this file's own argument that a countdown which is always
visible is one nobody reads on the day it matters. `EntitlementNotice` gets a
threshold of its own: the last day, or nothing, and it arrives already pressing
because there is no gentler step before it.
