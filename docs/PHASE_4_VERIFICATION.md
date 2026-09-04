# Phase 4 — verification checklist

What a person at the keyboard has to check, and what the machine already checks
by itself. Tick items here and record the outcome; anything left unticked stays
an unverified acceptance criterion in the phase report.

## 0. What is still unverified from earlier phases

- **German live dictation still cannot be self-verified.** The maintainer speaks
  Russian, English, and Ukrainian. German is the launch market.
- Ten minutes of repeated short recordings without memory growth.
- Unplugging or switching the input device mid-recording.

## 1. Automated (no microphone, no model, no Accessibility)

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
```

- [ ] `** TEST SUCCEEDED **`, 332 tests, 2 skipped (corpus-gated), no warnings.
- [ ] `ReviewPanelControllerTests` passed. It drives a real `NSPanel`
      through a real layout pass, because a panel that resizes its own
      window from inside that pass took the app down the first time a
      review appeared, with every other test still green.
- [ ] No permission dialog appeared during the run. Every Accessibility call,
      synthetic key event, and pasteboard write in the insertion path sits
      behind a protocol, and the tests use fakes.

```sh
xcodebuild build -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -configuration Release
```

- [ ] Release compiles, which keeps the Debug-only benchmark and prose corpus
      out of a shipping build.

## 2. Measurement (no microphone, no model)

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64' -only-testing:LocalDictationTests/ProseWarningDensityTests
```

- [ ] The table matches `docs/PHASE_4_MEASUREMENT.md`. A rise is a regression,
      not a new baseline.

## 3. Before granting Accessibility

Build and run **without** granting Accessibility access, or revoke it first.
This is the state every new user starts in.

1. [ ] Dictate a sentence with nothing worth checking. The text does **not**
       appear in the target application; a notice says it is on the clipboard,
       and the menu offers to fix that. **The quiet path must never fail
       quietly** — a fallback nobody is told about is indistinguishable from
       the app being broken.
2. [ ] ⌘V in the target application pastes exactly that text.
3. [ ] Everything from Phase 3 still works untrusted: the review appears, the
       replay plays, the dictionary saves.
4. [ ] Press **Allow…**, grant access in System Settings, and come back. The app
       notices without a relaunch.

> A development build loses Accessibility trust on every rebuild, because macOS
> keys the grant to the code signature. Expect to re-grant after each build.

## 4. The quiet path — the one this phase exists for

With trust granted, automatic insertion on, and the cursor in a text field in
another application.

5. [ ] Dictate "the meeting was moved to the usual room". The words appear at
       the caret. **No window opens at any point** — not the menu, and not a
       notice, because a successful insertion says nothing.
6. [ ] The insertion point ends up after the inserted text, and typing continues
       normally.
7. [ ] Dictate again with the caret directly after an existing word. Exactly one
       space is added, not two and not none.
8. [ ] Dictate into an empty field. No leading space.
9. [ ] Settings → Diagnostics → **Last insertion** names the method and the
       application, and **Audio lifetime → Retained frames** reads `0`.

## 5. The review path

10. [ ] Dictate "please transfer 1450 euro to Miller by Friday". A panel appears
        **in front of the application you were typing in**.
11. [ ] The application you were typing in is still frontmost — its title bar is
        not greyed out, and its caret is still blinking.
12. [ ] Play the fragment, toggle the raw transcript, and copy — all without the
        target application losing focus.
13. [ ] Press **Insert into …**. The text lands where the caret was.
14. [ ] Repeat and press **Discard** instead. **Nothing is inserted**, and
        nothing is on the clipboard from that dictation.
15. [ ] The panel appears on the screen the pointer is on, and over a full
        screen application.

## 6. Where it must refuse

16. [ ] Put the focus in a password field — a login screen, a password manager,
        or a `sudo` prompt in a terminal. Dictate.
17. [ ] Nothing is inserted, a sentence explains why, and **⌘V afterwards does
        not paste what you just said**. This is the one outcome that leaves the
        clipboard alone.

## 7. Where it must fall back rather than guess

18. [ ] Start dictating in one application, then switch to another before the
        text is ready. The text goes to the clipboard, and the message says the
        target changed. **Nothing is typed into either application.**
19. [ ] Start dictating in a text field, then click into a different field of the
        same application. Same: clipboard, and a message about the field.
20. [ ] Dictate with the focus in Finder, or anywhere with no text field. The
        text goes to the clipboard with a message about there being nothing to
        insert into.
21. [ ] Dictate with Witness's own Settings window in front. Same, and
        nothing is typed into the settings fields.

## 8. Behaviour that is easy to get wrong

22. [ ] **Supersede an insertion.** Press `⌥Space` again immediately after
        finishing a dictation. The new recording starts, and no text from the
        superseded one arrives late.
23. [ ] **Supersede a review.** Leave the panel open and press `⌥Space`. The
        panel disappears, nothing is inserted, and Retained frames is `0`.
24. [ ] **Clipboard preservation.** Copy something distinctive, then dictate into
        an Electron application (the paste path). After the text lands, ⌘V still
        pastes what you copied, not what you dictated.
25. [ ] **Automatic insertion off.** Turn it off in Settings. A quiet result now
        waits in the menu with an insert button, and pressing it inserts.

## 9. Compatibility matrix

26. [ ] `docs/PHASE_4_COMPATIBILITY.md` is filled in on a real machine, with
        versions recorded.

## 10. Logging

```sh
log show --predicate 'subsystem == "com.witnessmac.Witness"' --last 10m --info
```

- [ ] Insertion outcomes and target bundle identifiers appear.
- [ ] **No inserted text, no recognized word, no dictionary term, and no
      character read from another application appears in any log line.**
