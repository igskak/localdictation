# Phase 4 — application compatibility

Direct insertion is preferred and never promised. This is where that stops being
a sentence in a spec and becomes a table someone filled in on a real machine.

Fill a row by dictating one short sentence into a focused text field in the
application, with automatic insertion on, and recording what happened.

## What each column means

- **Method** — what the app reported in Settings → Diagnostics → Last insertion:
  `direct` (written through Accessibility), `paste` (synthetic ⌘V), or the
  clipboard reason it fell back with.
- **Caret** — whether the insertion point ended up after the inserted text, and
  an existing selection was replaced rather than duplicated.
- **Undo** — whether one ⌘Z in the application removes the inserted text.
- **Spacing** — whether the leading-space rule produced the right thing when
  inserting after an existing word.

A row that reads `clipboard` is a valid, honest result. A row where text lands
somewhere other than the focused field is a defect and blocks the phase.

## What the first live session found

Before any row below was filled in, ordinary use turned up the defect this table
exists to catch, and it is recorded here because it is the reason the **Method**
column cannot be read at face value.

Dictating into Safari produced `inserted:focusedElement` in the log, no notice —
a successful insertion says nothing — and no text in the page. Safari accepted
the write to `AXSelectedText` and did nothing with it. The app now measures the
field before and after a direct write and falls through to the paste path when
nothing changed, so a row that reads `direct` means the text was seen to arrive
rather than that an API returned `success`.

Dictating into Flock turned up the second half of the same lesson: an Electron
application describes no focused element at all until it is asked to build an
accessibility tree, and the app was reading that as "nothing to insert into".
It now asks every captured target for one, and pastes into an application that
still describes nothing.

When filling in a row, still check the field with your own eyes. The
verification catches a field that reports no change; it cannot catch one that
reports a change it did not make.

## Ways the text can fail to arrive

The table below is filled in one application at a time. This section is the
other half of the same question: the *kinds* of failure the insertion path can
produce, which application is likely to show each one, and whether anything
stands in the way today. It is written from the code and from the unified log on
the development Mac, and every measurement quoted here has a timestamp.

### Closed

- **A system panel in front.** `com.apple.loginwindow` took the front from a
  messenger twice inside six seconds on 2026-08-20 while its user did nothing
  but type. Read once, that is "you moved to a different application" and the
  text goes to the clipboard. A target that is not in front now gets 600 ms to
  come back.
- **An application that reads the pasteboard slowly.** The previous contents
  went back after a flat 200 ms whether the target had read them or not, so a
  busy Electron app, a virtual machine, or a remote desktop could lose the
  dictation with no notice. A readable field is now watched for up to 600 ms,
  the pasteboard goes back as soon as the text lands, and a field that reports
  itself unchanged is reported as *not* inserted.
- **A modifier still held.** The synthetic ⌘V carries whatever the user is
  physically holding, and ⇧⌘V or ⌥⌘V means something else in most editors. The
  paste now waits up to 100 ms for the modifiers to clear.
- **A write the application swallows.** Safari and parts of Electron accept a
  write to `AXSelectedText` and ignore it. Measured again on 2026-08-20 in
  Claude for Desktop: `The element accepted the write and did not change` →
  `falling back to paste` → inserted.
- **An Electron application that describes nothing.** Chromium builds no
  accessibility tree until asked. Every captured target is now asked, and one
  that still describes nothing is pasted into.
- **A ⌘V macOS refuses to let the app post.** Accessibility trust and
  permission to synthesize an event are two different answers, and they come
  apart silently. `AXIsProcessTrusted()` is settled once for the life of the
  process, so an app trusted at launch goes on reading and writing focused
  elements; the window server checks the right to synthesize on every post,
  against the code signature the application has *now*. An application replaced
  by a new build — every rebuild in development, every update a user installs —
  no longer matches the signature its grant was recorded against.
  Measured on 2026-08-31: every paste in the session produced two
  `Sender is prohibited from synthesizing events` errors from the window server,
  one per key event, while Claude for Desktop logged no `performKeyEquivalent:`
  at all and took the user's own ⌘V a second later. The grant in TCC named
  cdhash `2dc672…`; the application on disk had `22b9e4…`. `CGEventPost` returns
  `Void`, so the app saw an unchanged field and reported that the application
  would not accept the text — naming the target for something the target never
  saw. `CGPreflightPostEventAccess()` is now asked before the post, in the
  policy and again on the Electron fallback path that does not go through it,
  and the refusal says the permission stopped applying and where to restore it.
- **The first word of a dictation.** Not an insertion failure, but the same
  complaint from the user's side. Asking for the accessibility tree is a
  synchronous call into another process, and on 2026-08-20 Xcode took the full
  half-second messaging timeout to answer it: the hotkey went down at
  17:20:05.746 and the microphone opened at 17:20:06.325. The ask no longer
  blocks the hotkey.

### Closed since this table was written

- **A dictation that transcribes to nothing.** Two utterances of 8.8 s and
  10.1 s on 2026-08-20 at 17:19 produced `0 tokens`, and the app said nothing at
  all — insertion is skipped for empty text and `ReviewCoordinator` returns
  `.quiet`, which the user reads as "it did not insert". It now says which of the
  two silences it was: a microphone that never reached speech level names the
  input device, and speech that came back empty names the language profile it
  was asked in. See `docs/REFINEMENTS.md`.
- **A device that changes mid-sentence.** Not on this list when it was written,
  and the worst of the lot: `AVAudioEngineConfigurationChange` — AirPods
  connecting, a dock being plugged in — dropped the recording and discarded the
  captured audio into a `.failed` state. The recording now ends where the device
  went away and is still finished, transcribed, and delivered.

### Open

Each of these is a real way for a dictation not to arrive. None is fixed, and
the first two are decisions rather than defects.

- **Witness itself in front.** Dictating with the menu bar panel or
  Settings open captures no target, so the text goes to the clipboard with
  "there was no other application to put it in". Observed on 2026-08-20 at
  17:33:33. Remembering the last application that was in front would insert
  where the user expects — at the cost of activating another application, which
  is a visible window switch and needs a decision before it is built.
- **System-wide secure input stuck on.** `IsSecureEventInputEnabled()` is
  process-wide, and applications are known to leave it on after a password
  field, or when they exit while one is focused. While it is on, *every*
  dictation everywhere is refused — the worst failure mode in this list, because
  it looks like the app is broken rather than careful. The refusal now names the
  application holding the flag and the two things that clear it, which makes the
  state legible; it does not resolve it. The refusal is deliberate and protects a
  password field, and what to do about a flag nobody is holding any more is still
  a separate decision.
- **A target Accessibility cannot see into.** Remote desktop clients, virtual
  machine guests, XQuartz and X11 applications, some Java and Qt applications:
  the focused element is either absent or unreadable, so the paste cannot be
  verified and the app reports an insertion it could not confirm. In a guest OS,
  ⌘V may not even be the paste shortcut. This is the honest limit of the
  approach and belongs in the table as a row, not in the code as a promise.
- **An application where ⌘V is not "paste text".** Finder pastes files, an image
  editor pastes a layer, a read-only view does nothing. The verification catches
  it where the focused element is readable, and cannot elsewhere.
- **A terminal, and a modal editor inside one.** ⌘V in Terminal arrives as
  keystrokes, and in `vim`'s normal mode keystrokes are commands. The Terminal
  section below already asks for this decision; it is worth taking before the
  matrix is called done.
- **A clipboard manager.** Every paste-path insertion puts the dictation on the
  system pasteboard for a moment, and a clipboard manager keeps it. The change
  count guard also means our text stays on the pasteboard when a manager writes
  during the paste, instead of being restored away.

## Native

| Application | Version | Method | Caret | Undo | Spacing | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| TextEdit | | | | | | |
| Notes | | | | | | |
| Mail | | | | | | |

## Browsers

Check both a plain `<textarea>` and a rich editor, because they expose different
elements and often take different paths.

| Application | Version | Context | Method | Caret | Undo | Spacing | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Safari | | plain textarea | | | | | |
| Safari | | rich editor | | | | | |
| Chrome | | plain textarea | | | | | |
| Chrome | | rich editor | | | | | |

## Electron

The applications the paste path exists for.

Two rows below were taken from the unified log rather than from someone watching
the field, so their **Caret**, **Undo**, and **Spacing** columns say `not
checked` rather than guessing. The log can say the text arrived; only a person
can say it arrived in the right place.

That reservation turned out to be the right one and still not strong enough. On
2026-08-20 the paste path reported `inserted:syntheticPaste` without checking
anything — it slept 200 ms and said so — so both rows record what the app
claimed rather than what happened. Neither row is evidence that a synthetic ⌘V
ever reached either application, and on 2026-08-31 it demonstrably did not.
Both need dictating again, by a person watching the field, on a build whose
Accessibility grant matches its signature.

| Application | Version | Method | Caret | Undo | Spacing | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Slack | | | | | | |
| Notion | | | | | | |
| VS Code | | | | | | |
| Flock | | paste | not checked | not checked | not checked | 2026-08-20 17:46:47, `inserted:syntheticPaste into to.go.osx`. No direct write offered — the element is not settable. Two `loginwindow` activations in the same minute are why the target now gets a grace period |
| Claude for Desktop | | paste | not checked | not checked | not checked | 2026-08-20 17:47:17. Direct write accepted and swallowed, caught by the before/after measurement, pasted instead |

## IDEs

| Application | Version | Method | Caret | Undo | Spacing | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Xcode | | | | | | |
| JetBrains (which one) | | | | | | |

## Terminal

A terminal takes text and may act on it. If the right behaviour turns out to be
refusing rather than inserting, that is a decision to record here and implement,
not a row to leave blank.

| Application | Version | Method | Notes |
| --- | --- | --- | --- |
| Terminal or iTerm | | | |

## The refusal

The one row that must read the same everywhere.

| Where | Expected | Observed |
| --- | --- | --- |
| Any password field (login screen, password manager, `sudo` prompt) | Nothing inserted, **nothing on the clipboard**, and a sentence saying so | |

## Machine

Record what this was measured on, the way the Phase 2 benchmark does:

- macOS version:
- Mac model:
- Witness build:
- Date:
