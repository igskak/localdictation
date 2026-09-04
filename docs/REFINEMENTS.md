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
