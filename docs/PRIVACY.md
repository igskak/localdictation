# What Witness sends, and what it never sends

This is the working text of the privacy policy. `docs/PRODUCT_SCOPE.md` requires
every transmitted field, purpose, recipient and retention period to be written
down, and `AGENTS.md` makes the list itself the boundary: the app may send only
what is enumerated here, and a test fails when the shape of the activation
request changes.

The published version is `/datenschutz` on witnessmac.com, and it is written
from this file. When the table below changes, that page changes with it —
in that order, and before the version that made the change is released.

It is written from the code rather than from an intention. Every claim below
names the file that makes it true.

## The short version

Nothing you dictate leaves your Mac. Not the audio, not the transcript, not the
cleaned text, not your dictionary, not the names of the applications you dictate
into, and nothing derived from any of them. There is no account and no sign-in.

Four things can leave. Two because you pressed something, one because the app
cannot recognize a word without it, and one — three events about the trial —
that you can switch off in Settings → Privacy:

| What | When | To whom | Why |
| --- | --- | --- | --- |
| A request for the speech model | The first launch, automatically, and any later one where the model is missing — or when you press **Get the speech model** | Hugging Face, WhisperKit's host | Fetching a static file. One way — nothing is uploaded, and the request carries no identifier of you or this Mac |
| Your email address and a device identifier | You press **Send me a key** or **Send my key** | The Witness activation service, at `api.witnessmac.com` | Issuing a licence key for this Mac |
| A licence key you already hold | You press **Remove from this Mac** | The same service | Freeing one of the two Macs your licence covers |
| Three events about the trial, each with an app version, a macOS major and minor version, and a random number made at install | A trial starts, the app asks for an email, or it puts the offers on screen — unless you turned this off | The same service, at `api.witnessmac.com` | Counting how many people reach the wall and how many get past it |

That is the complete list. There is no fifth row.

The first row used to wait for a button. It no longer does: the weights are the
one thing the product cannot work without, so a fresh install starts fetching
them as it launches and says so in the menu bar and on the first-run screen. If
you would rather it did not, quit Witness before it finishes — nothing else in
the app reaches the network on its own.

## The audio, and why it is not on that list

Recognition runs on this Mac, in this process, against a model on this disk.
Audio is held in memory for the length of an utterance and released when the
next one begins or when you close the review; it is never written to disk, and
`AGENTS.md` forbids adding a feature that writes it without an explicit opt-in.

The dictionary, the risk warnings, the cleanup, and the review are all local
computation over local text. They have no network code in them at all.

## The activation request, field by field

`LocalDictation/Services/Licensing/HTTPActivationBackend.swift`

```json
{"device":"<32 hex characters>","email":"<the address you typed>"}
```

Two fields. `HTTPActivationBackendTests.testTheRequestCarriesTheEmailTheDeviceAndNothingElse`
fails if a third is ever added, which is how this document stays true.

- **The address** is the one you type, and it is used to issue a key, to mail it
  to you, and to recognise you when you activate a second Mac or replace one.
  It is not used for anything else. Marketing to it would need consent asked for
  separately — in Germany, §7 UWG.
- **The device identifier** is `SHA-256(salt + IOPlatformUUID)`, truncated to 128
  bits, and it is what makes a licence cover two Macs rather than any number of
  them. It cannot be turned back into a serial number, it is specific to this
  app, and it matches nothing outside it.
- **The user agent** is the word `Witness`, deliberately without a
  version. An app build and an OS build are not on the list above, so they are
  not sent.

The connection is HTTPS. A plain-HTTP endpoint makes the app report itself
unconfigured rather than send an address in the clear, and there is no setting
that relaxes that in any build.

## Where the service runs, and who else can see it

The activation service runs on **Cloudflare Workers**, and the licence table is
a **Cloudflare D1** database in Cloudflare's **EEUR (Eastern Europe)** region.
Cloudflare is a processor: it runs the code and stores the table, and it does
not get the data for any purpose of its own.

Payment runs on **Stripe**, which is the merchant of record for the sale. The
app never opens a payment page itself and never sees a card number — the buy
buttons hand a URL to your browser. What Stripe knows about a purchase is
governed by Stripe's own policy, and the only thing it passes to this service is
the address you bought with and an order identifier.

Nothing you dictate reaches either of them, and nothing could: the app has two
fields to send and neither can carry it.

## What the service stores

`Service/schema.sql` is the whole of it.

| Stored | Why | For how long |
| --- | --- | --- |
| Your email address, lowercased | Identifies the licence | The life of the licence |
| The device identifier | The two-Mac limit | The life of the licence, or until you release the Mac |
| Kind, issue date, expiry, key id | What was issued | The life of the licence |
| The payment provider's order id | Reconciling a payment, and invoices | As long as tax law requires |
| Your IP address, as a counter | Rate limiting, against abuse | 24 hours, as a count and not as a log |
| Provider identifiers for your purchase | Matching a later renewal or refund to your licence rather than to somebody else's | The life of the licence |
| The three product events above, as rows carrying only the five fields named | Counting the funnel | 90 days, then deleted — `Service/src/events.js`, and a test asserts the sweep |

The licence key itself is not stored. It is reproduced from the fields above
when you ask for it again, which is also why asking twice gives you the same key
rather than a second one.

Payment happens on the provider's own pages. The app never sees a card number
and neither does this service.

**Deleting your data**: write to the support address and the record is erased,
keeping only an anonymised order row where an invoice requires one. The
consequence is worth stating plainly, because it cannot be undone: no further
key can be issued for that address, so a Mac you replace afterwards cannot be
activated. Keys already on your Macs keep working — they are checked on the Mac,
against a signature, with no connection.

## Product events, field by field

`LocalDictation/Services/Telemetry/ProductTelemetryService.swift`

The app builds ten events about the licensing funnel. **Three of them are sent.
The other seven are written to the local log and go nowhere**, which is what
every earlier version of this app did with all ten — `docs/PHASE_8_DECISIONS.md`
D7 recorded that decision and `docs/REFINEMENTS.md` records reversing it for
these three.

| Event | Sent when |
| --- | --- |
| `trial_started` | Your first successful dictation — the moment the fourteen days start |
| `activation_requested` | You press **Send me a key** or **Send my key** |
| `paywall_shown` | The app puts the offers on screen, with which of the four reasons it did |

Each one is this, and nothing else:

```json
{"app_version":"0.3.0","event":"trial_started","install_id":"<a random UUID>","system_version":"15.0"}
```

`paywall_shown` adds a fifth field, `qualifier`, whose value is one of four
fixed words: `activationRequired`, `trialExpired`, `licenseExpired`,
`updateRequired`. There is no sixth field, and
`PrivacyDisclosureTests.testEveryFieldTheAppCanSendIsNamedInTheDocument` fails
if one is added without this document naming it.

- **`install_id`** is a random value made once, when the app is installed. It is
  derived from nothing — not from this Mac, not from you, not from your licence
  — so it cannot be joined to the device identifier a licence carries, to your
  email address, or to anything outside this product. `TelemetryBoundaryTests`
  asserts that it is not the device hash.
- **`app_version`** and **`system_version`** are what they say. The macOS version
  is major and minor only: a rare build number is an identifier.
- **`event`** and **`qualifier`** come from an enum with no free-form string
  anywhere in it, so there is nothing for a transcript, a dictionary term, or
  the name of an application to be passed into even by accident.
  `TelemetryBoundaryTests` asserts that too, and the service refuses any event
  name or qualifier outside the lists above.

**Turning it off.** Settings → Privacy, one switch, which is on when the app is
installed. The first-run screen says so before the first of these events can
happen. Off means none of the three is sent and nothing else about the app
changes — not the trial, not the dictation, not the licence.

**Why it is on by default, said plainly.** These three events exist to answer
one question: how many people stop at the wall rather than paying. A count that only
includes people who opted in is a count of people who did not stop, which
answers a different question. That is the reason, it is not a good enough
reason to be quiet about, and so it is written on the first-run screen and
here, and the switch is one click away.

Nothing about what you dictate is in any of this, and nothing could be: the
message has five fields and none of them can hold a word you said.

## Crash reports and diagnostics

There are none. The app writes to the unified log on your Mac, which stays on
your Mac. macOS may offer to send Apple a crash report if the app crashes; that
is between you and Apple, and this app neither reads it nor asks for it.

## Children

The product is not directed at children and asks for nothing about age.

## Changes

The list at the top is the promise. If a version ever sends something new, this
document says so before that version is published, and the app's request stays
exactly as wide as this document is.
