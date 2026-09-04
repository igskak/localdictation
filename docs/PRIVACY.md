# What LocalDictation sends, and what it never sends

This is the working text of the privacy policy. `docs/PRODUCT_SCOPE.md` requires
every transmitted field, purpose, recipient and retention period to be written
down, and `AGENTS.md` makes the list itself the boundary: the app may send only
what is enumerated here, and a test fails when the shape of the activation
request changes.

It is written from the code rather than from an intention. Every claim below
names the file that makes it true.

## The short version

Nothing you dictate leaves your Mac. Not the audio, not the transcript, not the
cleaned text, not your dictionary, not the names of the applications you dictate
into, and nothing derived from any of them. There is no account, no sign-in, and
no analytics.

Three things can leave, all of them because you pressed something:

| What | When | To whom | Why |
| --- | --- | --- | --- |
| A request for the speech model | You press **Prepare speech model…** | Hugging Face, WhisperKit's host | Fetching a static file. One way — nothing is uploaded |
| Your email address and a device identifier | You press **Send me a key** or **Send my key** | The LocalDictation activation service, at `localdictation-activation.localdictation-activation.workers.dev` | Issuing a licence key for this Mac |
| A licence key you already hold | You press **Remove from this Mac** | The same service | Freeing one of the two Macs your licence covers |

That is the complete list. There is no fourth row.

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
- **The user agent** is the word `LocalDictation`, deliberately without a
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

## Product events

`LocalDictation/Services/Telemetry/ProductTelemetryService.swift` builds ten
events about the licensing funnel — installed, trial started, activation
requested, and so on — each carrying an app version, an OS major and minor
version, and a random identifier made at install that is derived from nothing
and cannot be joined to the device identifier above.

**None of them is transmitted.** They are written to the local log, and
`docs/PHASE_8_DECISIONS.md` D7 records the decision to ship it that way. If that
ever changes, it changes with consent asked for in the app and with a row added
to the table at the top of this document — not quietly.

The type they are built from has no free-form field anywhere in it, so there is
nothing for a transcript to be passed into even by accident.
`TelemetryBoundaryTests` asserts that.

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
