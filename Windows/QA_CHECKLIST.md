# Witness for Windows closed-beta QA checklist

Use this checklist only with an approved tester kit and the fixed synthetic
phrases below. Mark **pass**, **fail**, **blocked** or **not applicable** for
each case. A blocked physical case is evidence still pending, not a pass.

## Manual environment record

Copy these fields into the bug template or the coordinator's result sheet:

| Field | Required value |
| --- | --- |
| Witness | version, build, source revision, verified installer SHA-256 |
| Windows | edition, version, OS build, x64 system type |
| Machine | manufacturer/model (no serial), CPU, installed RAM |
| Graphics | each GPU model and driver version |
| Speech | model ID/hash from `BUILD_INFO.json`; backend Witness reports |
| Audio | built-in/USB/Bluetooth category; default/specific selection |
| UI | resolution, scale, high contrast, UI language |
| Language | selected speech-language order and dictionary capabilities |

## Fixed synthetic phrase set

Read naturally. For leading-silence cases, wait two seconds after starting the
recording and then speak. Do not replace these with personal text.

| ID | Language | Phrase |
| --- | --- | --- |
| EN-01 | English | The blue lantern is on table forty-two. |
| EN-02 | English | Do not send seven boxes before March fifth. |
| EN-03 | English | Morgan tested the quiet engine near Cedar Station. |
| EN-04 | English | The total is one hundred twenty-three dollars and forty-five cents. |
| EN-05 | English | I did not approve the second proposal. |
| EN-06 | English | Start after two seconds of silence, then close the silver gate. |
| DE-01 | German | Die blaue Laterne steht auf Tisch zweiundvierzig. |
| DE-02 | German | Sende sieben Kisten nicht vor dem fünften März. |
| DE-03 | German | Marta prüft den leisen Motor am Bahnhof Linden. |
| DE-04 | German | Der Betrag ist einhundertdreiundzwanzig Euro und fünfundvierzig Cent. |
| DE-05 | German | Ich habe den zweiten Vorschlag nicht bestätigt. |
| DE-06 | German | Beginne nach zwei Sekunden Stille und schließe dann das silberne Tor. |
| RU-01 | Russian | Синий фонарь стоит на столе сорок два. |
| RU-02 | Russian | Не отправляй семь коробок до пятого марта. |
| RU-03 | Russian | Марта проверяет тихий двигатель у станции Липовая. |
| RU-04 | Russian | Сумма — сто двадцать три рубля сорок пять копеек. |
| RU-05 | Russian | Я не подтверждал второе предложение. |
| RU-06 | Russian | Начни после двух секунд тишины и закрой серебряные ворота. |
| UK-01 | Ukrainian | Синій ліхтар стоїть на столі сорок два. |
| UK-02 | Ukrainian | Не надсилай сім коробок до п'ятого березня. |
| UK-03 | Ukrainian | Марта перевіряє тихий двигун біля станції Липова. |
| UK-04 | Ukrainian | Сума — сто двадцять три гривні сорок п'ять копійок. |
| UK-05 | Ukrainian | Я не підтверджував другу пропозицію. |
| UK-06 | Ukrainian | Почни після двох секунд тиші й зачини срібні ворота. |

## Installation, trust and setup

- [ ] I-01 SHA-256 matches `SHA256SUMS.txt`; build/source match the assignment.
- [ ] I-02 Installer has the expected verified publisher and needs no admin.
- [ ] I-03 Unsupported OS/architecture is not represented as supported.
- [ ] I-04 Terms/privacy contain no placeholders and open from License settings.
- [ ] I-05 First run requires a non-empty ordered language selection.
- [ ] I-06 Model disclosure appears before network use; size/hash verification
  succeeds; restart reuses the model offline.
- [ ] I-07 Activation is explicit, isolated to the beta and survives restart.
- [ ] I-08 Denied microphone access is actionable and never shows a fake app
  permission prompt.

## Capture, language and recognition

- [ ] C-01 Hold mode stops when the primary key is released first.
- [ ] C-02 Hold mode stops when a modifier is released first.
- [ ] C-03 Toggle mode starts and stops exactly once per press.
- [ ] C-04 A shortcut conflict is visible and the shortcut can be changed.
- [ ] C-05 Default, built-in where known, USB and Bluetooth inputs report their
  actual resolved/fallback state; selection changes on the next capture only.
- [ ] C-06 Unplug mid-sentence preserves only already-buffered detected speech
  for local processing and shows interruption.
- [ ] C-07 Lock, logoff/disconnect and sleep/wake end capture safely.
- [ ] C-08 EN/DE/RU/UK automatic choice is correct for all six phrase IDs,
  including `-06` leading silence.
- [ ] C-09 Temporary explicit-language pin affects only the intended phrase.
- [ ] C-10 Every selected non-verified language can recognize; no uncalibrated
  cleanup/dictionary warning is silently enabled.
- [ ] C-11 Empty/no-speech and ten-minute-bound cases end without stale audio.

## Cleanup, review and memory-only state

- [ ] R-01 Negation, numbers, dates, amounts and synthetic names remain visible
  and are not semantically rewritten behind a polished result.
- [ ] R-02 Attention highlights explain uncertainty; quiet results do not keep
  replay audio.
- [ ] R-03 Replay contains only the flagged in-memory fragment and disappears
  after dismissal, replacement or restart.
- [ ] R-04 Recent history contains at most ten non-empty results; protected
  refusals are excluded; restart clears it.
- [ ] R-05 Session glossary affects review only for its language, rejects
  duplicates/oversize entries and is empty after restart.
- [ ] R-06 Missing Windows dictionary is shown as unavailable and does not mark
  every word wrong.

## Insertion and protected clipboard

Run Notepad, Word, Chrome/Edge textarea and contenteditable, VS Code and one
desktop messenger as an ordinary user.

- [ ] P-01 Insertion targets the PID and top-level window captured at hotkey
  start; switching windows before completion prevents automatic side effects.
- [ ] P-02 Standard Edit selection replacement is exact and read back.
- [ ] P-03 Fallback waits for hotkey modifiers, pastes once and never adds Enter.
- [ ] P-04 Password fields, locked desktop, elevated target and unknown/timed-out
  protection never receive an automatic paste or copy.
- [ ] P-05 Clipboard history and Cloud Clipboard do not receive Witness text.
- [ ] P-06 External clipboard changes are not overwritten during restore.
- [ ] P-07 Starting another dictation before paste completes does not duplicate
  or insert the stale result.

## Settings, accessibility and localization

- [ ] U-01 All six Settings destinations and onboarding are reachable by
  keyboard with visible focus and logical screen-reader names/order.
- [ ] U-02 100%, 150%, 200% scale; compact and large windows; high contrast do
  not clip controls or create click-blocking decoration.
- [ ] U-03 English and German show no missing keys, broken placeholders or
  speech-language-driven UI switches.
- [ ] U-04 Audio, language order, hold/toggle, startup and boundary settings
  take effect at their documented boundary and survive restart where promised.
- [ ] U-05 Diagnostics contains only technical counts/capabilities, never
  dictated text, vocabulary, application content or audio.

## Update, uninstall and preservation

- [ ] A-01 Startup makes no update request and never auto-applies a package.
- [ ] A-02 Check, Download and Install/restart are separate explicit actions.
- [ ] A-03 Tampered metadata/package, wrong key/channel/architecture, downgrade
  and an uncovered product major fail before apply.
- [ ] A-04 Updating baseline to successor preserves settings, entitlement,
  model hash, hardware identity, microphone and shortcut choice.
- [ ] A-05 Successor starts with empty glossary/history/review audio.
- [ ] A-06 Update is refused while capture, processing, insertion or replay is
  active and the current phrase is not lost.
- [ ] A-07 Uninstall removes binaries, preserves documented local data, sends no
  remote slot-release request, and reinstall reads the preserved state.

## Performance and 30-minute soak

Run each assigned backend separately; record the backend Witness reports.

- [ ] S-01 Record cold model-load time, then five warm stop-to-result times for
  each language. Submit p50/p95 numbers without recognized text.
- [ ] S-02 Repeat short phrases continuously for 30 minutes, alternating quiet
  and flagged review results. Record memory and handle counts after warm-up,
  15 minutes and 30 minutes.
- [ ] S-03 Memory reaches a plateau; history stays at ten; retained review audio
  is zero or one current recording; handles/buffers do not grow monotonically.
- [ ] S-04 Run one five-minute phrase and confirm bounded progress, completion
  or an explicit recoverable error.
- [ ] S-05 On an 8 GB machine, resource exhaustion is explicit and recoverable;
  no content-bearing crash dump or automatic diagnostic upload is created.

## Result summary

- Cases passed / failed / blocked / not applicable:
- Phrase choices correct per language (count / 6):
- Recognition word errors per language (aggregate count only):
- Critical semantic errors (negation/number/date/name count only):
- False attention warnings (count / phrases):
- Backend and latency p50/p95:
- Warm-up / 15 min / 30 min memory and handles:
- Blocking defects filed by checklist ID:
