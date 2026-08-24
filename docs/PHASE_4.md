# Phase 4 — system insertion and app compatibility

## Objective

Close the last stage of the pipeline: the text stops being something the user
copies out of LocalDictation and becomes something that appears where they were
already typing.

```text
review decision
  -> no review needed: insert into the captured target immediately
  -> review shown: insert after the user confirms
  -> insertion attempt: Accessibility -> synthetic paste -> clipboard
  -> outcome is always visible: inserted, or "it is on your clipboard"
```

The measure of success is what the quiet path looks like. Today, a sentence with
no amount, date, or name still ends with the user clicking the menu bar item and
pressing **Copy**. After Phase 4 that path shows no window at all: hold `⌥Space`,
speak, release, and the words are in the document. The review strip stays exactly
where Phase 3 put it — in front of the text, when the risk policy says the
interruption is earned, and nowhere otherwise.

Phase 4 ends before licensing. Nothing about money, trials, or telemetry.

## Explicit non-goals

- Licensing, activation, trial, paywall, Stripe, telemetry, Developer ID
  signing, notarization, updater (Phase 5).
- Translation, style presets, aggressive rewriting — post-MVP by
  `docs/PRODUCT_SCOPE.md`, and no more admissible here than in Phase 3.
- Persistent history. Transcripts and audio stay memory-only.
- Streaming insertion while the user is still speaking. The product promise is a
  result that can be checked before it lands, and partial text cannot be.
- Editing text already in the target application: no undo integration, no
  reformatting of surrounding content, no reading the document for context
  beyond the single-character rule below.
- Scripting or automating other applications by any route other than the
  focused-element and keyboard paths described here.

## What Phase 4 inherits and must not break

- Audio is memory-only and its lifetime is bounded by the review decision. Phase
  4 adds no reason to hold it longer: insertion needs the text, not the samples.
- The Phase 1 no-disk-writes test still passes. The glossary remains the only
  thing that persists.
- No recognized word reaches a log line. Phase 4 adds a second thing that must
  never be logged: the identity of what the user was typing into is loggable,
  what they typed is not.

## Design decisions

These are decided, with the reasoning recorded, so they are not re-opened
without new evidence.

### The target is captured when recording starts, not read when inserting

Between `⌥Space` going down and the text being ready there is transcription, and
possibly a review the user takes seconds over. The frontmost application at the
end of that is not reliably the one they spoke into.

So the insertion target — the running application — is captured at the moment
capture starts, and re-validated immediately before insertion. If the target has
changed, quit, or lost focus, **the app does not guess**: it falls back to the
clipboard and says so.

A wrong target is the worst outcome available in this phase. Text meant for a
document lands in a Slack message that sends on Return, a terminal that runs it,
or a commit message. Compared to that, "your text is on the clipboard" is a good
day. Wrong-target insertions are a gate at zero, not a rate to optimize.

#### A system panel in front is not the user moving away

Re-validating once, at the instant the text happens to be ready, turned out to
be too literal a reading of "still frontmost". macOS puts its own windows in
front without the user going anywhere: the unified log on the development Mac
has `com.apple.loginwindow` in front of a messenger twice inside six seconds
while its owner did nothing but type, and a Touch ID sheet, a Wi-Fi prompt, or a
screen lock does the same. Read once, any of those becomes "you moved to a
different application" — wrong, and impossible to act on.

So a target that is not in front is given 600 ms to come back, re-read every
40 ms. This weakens nothing: the text still only ever goes into the application
it was spoken into, and waiting is safe in the way that guessing is not. It
changes only how long that application is allowed to sit behind a system panel.
A user who really did switch applications waits 600 ms for their sentence about
the clipboard instead of getting it instantly.

Inside that application, the text goes wherever the caret is. The first version
went further and required the *field* to be the one dictated into as well,
comparing the focused element captured at the hotkey against the one focused at
insertion. That check was removed: an `AXUIElement` for a web or Electron field
is not stable across the seconds a transcription and a review take, so it fired
on fields nobody had left, and the text went to the clipboard with a sentence
about moving focus that the user had not done. The gate that earns its place is
the application; between two fields of the app you dictated into, the caret is a
better guess than a stale element reference.

### Review must not take focus

Phase 3 put the review strip inside the `MenuBarExtra` window, which the user
opens by clicking. That was right when the strip was the destination. In Phase 4
it stands between the user and their own document, and the click that opens it
would move focus out of the field the text is going into.

**Review is presented in a non-activating floating panel** — an `NSPanel` with
`.nonactivatingPanel`, floating window level, appearing on its own when a review
is required, and dismissed when the review ends. It takes clicks without
activating LocalDictation, so the target application stays frontmost and the
caret stays where it was.

The alternative — activate for review, then restore focus afterwards — was
rejected. Restoring focus across Electron apps and browser text fields is
unreliable, and a lost caret is a lost insertion point. Not taking focus in the
first place is a smaller mechanism than putting it back.

The menu bar panel keeps showing the last result as it does today. It is the
place the user goes when something went wrong, not the primary surface.

The panel offers one way out per direction: **Discard**, and the insert action
named for where the text is going. It carries no **Copy** button. Copying was
the whole of the Phase 3 exit and is now a second way to do what the primary
button does, offered alongside it — and a user who presses it has to paste by
hand for no reason, because every path that cannot insert already leaves the
text on the clipboard and says so. Copy remains where insertion is impossible:
in the menu bar's result view, and in the panel itself when the app has no
insertion service at all.

### Accessibility first, but Accessibility is not promised

Three methods, tried in order, each with a recorded outcome:

1. **Focused element write.** Set `kAXSelectedTextAttribute` on the focused
   element, after checking it is settable. This respects the selection, involves
   no clipboard and no synthetic events, and behaves best in native apps.
   Accepting the write is not the same as applying it — see *A write is not
   believed, it is checked* below — so the field is measured before and after,
   and a write that changed nothing falls through to the next method.
2. **Synthetic paste.** Write to the pasteboard, post ⌘V, restore the previous
   pasteboard contents once the paste has been **seen to land**. Needed where
   the element is not exposed or not settable — much of Electron, some web
   fields — and used for **anything focused that cannot be written directly**,
   whatever the application says about it. See *An application is not asked for
   permission to insert* below.

   Restoring after a fixed delay was a bet that every application reads the
   pasteboard within it. One that is busy, or that is talking to a virtual
   machine or a remote desktop, reads it later — and by then the previous
   contents are back and the user's dictation is gone, with no notice, because
   the app had already called it an insertion. So a readable field is watched
   for up to 600 ms and the pasteboard goes back the moment the text arrives,
   which is usually sooner than the old fixed wait. A field that reports itself
   unchanged for the whole window did not get the text, and says so instead of
   reporting an insertion. A field that describes nothing at all cannot be
   watched, so it gets the settling delay and the benefit of the doubt, exactly
   as an unverifiable direct write does.

   The ⌘V also waits for the user's fingers to come off the modifier keys.
   A synthetic ⌘V carries whatever is physically held down with it, and ⇧⌘V is
   "paste and match style" in one application, "paste as plain text" in another,
   and a Markdown preview in a third.
3. **Clipboard only.** The text is on the clipboard and the user is told, in one
   line, that they need to paste it.

`docs/ARCHITECTURE.md` already says direct insertion is preferred but never
promised for every target. The third method is what makes that honest: it is a
normal outcome with its own message, not an error state.

### An application is not asked for permission to insert

The first version asked the focused element whether it was a text field —
a text role, or a settable value — and fell back to the clipboard when the
answer was no. That question turned out to be the wrong one. Electron and
Chromium describe a focused web view as a group or a web area and say nothing
about the field inside it, so a real, focused, perfectly writable message box
came back as "no text field in focus" and the user was left pasting by hand.
A live session produced exactly that against Claude for Desktop.

So the only thing the element is asked now is whether it can be **written**
through Accessibility, which decides between method 1 and method 2. Anything
focused that cannot is pasted into. What guards an insertion is the target and
the focus being unchanged and the secure checks — facts about where the text is
going — and not how well the application describes itself.

That went one step further after Flock. An Electron application describes *no*
focused element at all until an assistive technology asks it to build an
accessibility tree, so "nothing is focused" turned out to mean "nobody asked" —
and the message box the user was looking at took ⌘V perfectly well. Two things
changed: the app now asks (below), and an application that still describes
nothing is pasted into rather than copied from.

So Accessibility decides only *how* the text goes in, never whether it goes in.
The clipboard is left for the cases that are about where the text is going and
not about how well an application describes itself: no trust, no other
application in front, and the target moving away.

### Electron is asked for its accessibility tree

Chromium builds no accessibility tree until an assistive technology asks for
one, and Electron exposes that request as a settable `AXManualAccessibility`
attribute on the application element. Without it a focused message box is
invisible: no element, no role, no way to write directly, and nothing to check a
secure field against.

The app sets it on the captured target at the hotkey, not at insertion, because
the tree is built asynchronously — recording and transcription are seconds the
application can spend building it. Applications that are not Electron ignore the
attribute, which is why the target is not interrogated first. Each process is
asked once.

### A write is not believed, it is checked

`AXUIElementSetAttributeValue` returning `success` means the element accepted
the message, not that any text appeared. The first live session found Safari
doing exactly that: the app logged `inserted:focusedElement into com.apple.Safari`,
showed no notice — a successful insertion says nothing, by design — and the
document was unchanged. The user pressed the one button on the panel and
nothing at all happened, which is the worst outcome this phase can produce,
because it is indistinguishable from the app being broken.

So a direct write is verified against the field itself. Before writing, the
element is asked how many characters it holds and where its insertion point is;
afterwards it is asked again, twice — immediately, and once more after a short
settle, because a web editor that keeps the field's contents in its own state
can let the write through and then put its own value back. If the field reads
exactly as it did before, the write did not land and the paste path takes over.

Both numbers are non-content by construction: a length and a caret position say
that a field changed and nothing about what is in it. Neither is stored and
neither is logged.

An element that reports neither number cannot be checked, and there the API's
own answer stands. Pasting on top of a write that did land would insert the text
twice, which is worse than the silence this check exists to end.

### Secure input is a refusal, and the clipboard is not a consolation prize

When `IsSecureEventInputEnabled()` is true, or the focused element's subrole is
`AXSecureTextField`, insertion is refused outright. Synthetic keystrokes would be
swallowed anyway, but the rule is not about what works: dictation does not belong
in a password field.

In this case alone the text is **not** placed on the clipboard either. A password
field means a login screen or a password manager; quietly leaving spoken text on
the system clipboard there is a leak in exchange for nothing. The result stays in
the app, visible, and the user can copy it deliberately.

### The app invents at most one space

Whether a leading space is needed depends on the character before the caret, and
reading that character is reading the user's document. The rule is therefore
exactly one rule, and no more: **if the character immediately before the
insertion point is readable and is not whitespace or an opening bracket, one
space is inserted before the text.** Nothing else about the surroundings is read,
kept, or logged. If the character cannot be read, no space is added.

Everything else that lands in the target is exactly the text the review showed —
the same string the **Copy** button would have produced.

### A false warning now costs real time

Phase 3 measured 25.4 marks per hundred words on the smoke corpus. That corpus
was built so every sentence carries an amount, a date, a name, and a negation, so
the number is an upper bound rather than a typical one — but in Phase 3 the cost
of a needless mark was a strip in a panel the user had opened anyway. In Phase 4
it is a panel that interrupts the quiet path.

So the number stops being an observation and becomes a requirement: false-warning
density is measured on **ordinary prose** as well as the critical-token corpus,
and the flag threshold is revisited against that measurement before Phase 4 is
called complete. Raising the threshold is a legitimate outcome; leaving it
unexamined is not.

The measurement and what it changed are in `docs/PHASE_4_MEASUREMENT.md`.

## Required behavior

### Accessibility permission boundary

- An `AccessibilityPermissionService` protocol with an injected implementation,
  following the `MicrophonePermissionService` pattern from Phase 1.
- Authorization is explicit state — trusted or not trusted — and is a normal
  state, not a precondition. Every part of the app that worked in Phase 3 keeps
  working untrusted; only insertion is unavailable.
- The prompt is never shown at launch. It is requested the first time insertion
  is actually attempted, with an explanation of what it is for.
- A route to System Settings → Privacy & Security → Accessibility, as the
  microphone service already does for its own pane.
- Trust has no reliable change notification. The state is re-read when the app
  becomes active, and the UI must recover without a relaunch once the user grants
  it.
- A rebuilt development build loses its Accessibility trust because its code
  signature changes. This is a fact about the platform, not a defect; document it
  in the README so the next person does not spend an hour on it.

### Insertion boundary

- A `TextInsertionService` protocol with an injected implementation. No AX or
  `CGEvent` call may appear outside it, so tests never touch the real system.
- `InsertionTarget`: the captured application. Non-content by construction — a
  bundle identifier, a process identifier, and a display name. It must be
  comparable, because re-validation is a comparison.
- `InsertionOutcome`: `inserted(method)`, `copiedToClipboard(reason)`, or
  `refused(reason)`. Every attempt produces exactly one, and every one of them is
  surfaced to the user.
- The service is called from the coordinator on the main actor, but any call that
  can block on another process must not block the UI.

### Pasteboard handling

- The synthetic-paste path saves the current pasteboard contents, writes the
  text, posts the key event, and restores.
- Restoration is guarded by `NSPasteboard.changeCount`: restore only if nothing
  else changed the pasteboard in the meantime.
- Restoration of arbitrary pasteboard types is best-effort and must be described
  as such. The standard text types are restored; exotic types may not be.
- When the outcome is `copiedToClipboard`, the text stays there deliberately and
  nothing is restored over it.

### Lifecycle and the state machine

- `RecordingState` gains `.inserting`, entered from `.transcribing` when no
  review was needed and from `.reviewing` when the review is accepted.
- Illegal transitions are rejected rather than silently applied, as in Phases 1
  through 3.
- A dismissed review inserts nothing. Dismissal is the user saying no.
- A hotkey press during insertion supersedes it as cleanly as it supersedes a
  review today; no stale text may land after a new recording has started.
- `copiedToClipboard` and `refused` return to `.ready` with a visible message.
  They are not `.failed`: the text was not lost, and the promise held.

### Settings

- **Insert automatically when no review is needed** — a single toggle, default
  on. Off means every result waits for a confirmation, for users who want the
  keystroke to be theirs.
- The insertion method actually used for the last result is visible in developer
  diagnostics, because it is the first thing anyone will ask when an app
  misbehaves.

### Compatibility matrix

`docs/PHASE_4_COMPATIBILITY.md`, filled in by hand on a real machine, recording
per application: the class it belongs to, the method that worked, whether the
caret and selection survived, whether the target's own undo reverses the
insertion in one step, and the macOS and application versions it was checked on.

Minimum coverage, one per class and the named ones explicitly:

- Native: TextEdit, Notes, Mail.
- Browsers: Safari and Chrome, in a plain `<textarea>` and in a rich editor.
- Electron: Slack, Notion, VS Code.
- IDEs: Xcode, one JetBrains IDE.
- Terminal: Terminal or iTerm — where the correct behavior may well be to
  refuse, and if so that is a recorded decision.
- A password field, to prove the refusal.

An application that only works through the clipboard is a valid row. An
application where text lands in the wrong place is a defect.

### Privacy

- The inserted text is never logged, never persisted, and never leaves the
  machine. The Phase 3 rule holds unchanged.
- The target application's identity may appear in local logs and developer
  diagnostics, because compatibility cannot be debugged without it. It may
  **not** appear in any transmitted event — `docs/PRODUCT_SCOPE.md` and
  `AGENTS.md` already forbid application names in telemetry, and Phase 5 must
  inherit that intact.
- The single character read before the caret is used for the spacing rule and
  discarded immediately. It is never logged.

## Measurement

Phase 4 adds two numbers to the non-negotiable list in `docs/ARCHITECTURE.md`
and completes a third that Phase 2 left half-measured:

- **Direct-insertion success rate, per application class** — how often method 1
  or 2 succeeded rather than falling through to the clipboard.
- **Wrong-target rate** — a gate at zero, not a percentage. Any occurrence is a
  defect that blocks the phase.
- **End-of-speech to text-in-target latency.** Phase 2 measured to a usable
  transcript. This is the number the user actually experiences, and it includes
  the insertion attempt.
- **Review-to-insert time** when a review was shown, so the cost of the
  interruption is a measured quantity rather than an impression.
- **False-warning density on ordinary prose**, per language, alongside the
  existing critical-token corpus figure.

## Acceptance criteria

- Builds and tests under Swift 6 complete concurrency, without warnings, and
  Release still compiles with the Debug-only benchmark code excluded.
- Dictating into a text field in another application inserts the text there, with
  no window shown, when the risk policy says no review is needed.
- When a review is required, the panel appears without taking focus from the
  target application, and insertion happens only after the user accepts.
- A dismissed review inserts nothing.
- Insertion never lands in an application other than the one captured at the
  start of the recording. Where the target is gone or changed, the outcome is the
  clipboard and the user is told.
- A secure text field or enabled secure input produces a refusal, with nothing
  written to the pasteboard.
- The pasteboard is restored after a synthetic paste, and is not restored when
  the clipboard is the deliberate outcome.
- Insertion is unavailable but the whole rest of the app works when
  Accessibility trust has not been granted; granting it recovers without a
  relaunch.
- Every insertion path is unit-tested against a fake insertion service, with no
  AX call, no synthetic event, and no permission dialog in the test run.
- Audio is still released at the review decision; the no-disk-writes test still
  passes; the glossary is still the only thing that persists.
- The compatibility matrix is filled in on a real machine and committed.
- The flag threshold has been revisited against a false-warning measurement on
  ordinary prose, and the outcome — changed or deliberately unchanged — is
  recorded.
- No licensing, trial, Stripe, telemetry, or updater code is introduced.

## Completion report

- Files and architecture introduced.
- The compatibility matrix, and which applications required which method.
- Direct-insertion success rate per class, end-of-speech to text-in-target
  latency, and review-to-insert time.
- False-warning density on ordinary prose, and what happened to the threshold.
- Commands run and their results.
- Manual checks performed, per language and per application class.
- Any acceptance criterion that remains unverified.
