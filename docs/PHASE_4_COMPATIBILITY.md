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

When filling in a row, still check the field with your own eyes. The
verification catches a field that reports no change; it cannot catch one that
reports a change it did not make.

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

| Application | Version | Method | Caret | Undo | Spacing | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Slack | | | | | | |
| Notion | | | | | | |
| VS Code | | | | | | |

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
- LocalDictation build:
- Date:
