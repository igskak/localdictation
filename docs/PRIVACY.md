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

The following requests can leave. Activation and updates follow your action;
the model download occurs when its files are missing; nine events about setting
the app up and about the trial can be switched off in Settings → Privacy:

| What | When | To whom | Why |
| --- | --- | --- | --- |
| A request for the speech model, and one for the list of its files and their sizes | The first launch, automatically, and any later one where the model is missing — or when you press **Get the speech model** | Hugging Face, WhisperKit's host | Fetching a static file, and knowing how large it is so the progress bar can say how much is left. One way — nothing is uploaded, and neither request carries an identifier of you or this Mac |
| Your email address and a device identifier | You press **Send me a key** or **Send my key** | The Witness activation service, at `api.witnessmac.com` | Issuing a licence key for this Mac |
| A licence key you already hold | You press **Remove from this Mac** | The same service | Freeing one of the two Macs your licence covers |
| Nine events about setup and the trial, each with an app version, a macOS major and minor version, and a random number made at install | The app is installed, the speech model starts arriving, arrives or fails, a press finds it still arriving, the microphone is refused, a trial starts, the app asks for an email, or it puts the offers on screen — unless you turned this off | The same service, at `api.witnessmac.com` | Counting how many installations reach a first dictation, and how many people reach the wall and get past it |
| Update catalogue HTTPS request: requested URL, IP address, User-Agent with Witness name/version and Sparkle version | You press **Check for updates** in Settings | GitHub Releases | Looking for a newer signed version |
| Signed update file HTTPS request: requested URL, IP address, User-Agent | You confirm an offered update | GitHub Releases | Downloading the chosen version for installation |

That is the complete list. The update requests contain no audio, transcript,
dictionary, licence key, email address, application content, or data derived
from dictated content. Automatic update checks, automatic installation and
Sparkle system profiling are disabled in `LocalDictation/Resources/Info.plist`.
The catalogue and update file are hosted by GitHub. We receive and retain no
GitHub request logs. GitHub may retain IP addresses and request metadata under
its [privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement),
which does not specify a fixed retention period for these requests. Sparkle's
update state remains locally in app preferences until those preferences are removed.

The first row used to wait for a button. It no longer does: the weights are the
one thing the product cannot work without, so a fresh install starts fetching
them as it launches and says so in the menu bar and on the first-run screen. If
you would rather it did not, quit Witness before it finishes. The update
checker does not make a request until you press its button.

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

Payment runs on **Stripe**, which processes the card payment for the seller,
Ihor Skakovskyi (IČO 17328691). The app never opens a payment page itself and
never sees a card number: the buy buttons hand a URL to your browser. What
Stripe knows about a purchase is governed by Stripe's own policy, and the only
things it passes to this service are the address you bought with and the
identifiers of the order and its payment, which a later refund refers to.

Nothing you dictate reaches either of them, and nothing could: the app has two
fields to send and neither can carry it.

### What the service tells PostHog

`Service/src/analytics.js`

The service reports four facts about the business to **PostHog**, in PostHog's
**EU** region, the same project that measures the website: a trial was issued, a
licence was bought, a licence renewed, a licence was refunded. That is what puts
trials and sales on one dashboard next to the site's visits and downloads.

Each event carries the licence's own random identifier, the kind of licence, the
payment provider's name, whether a purchase was an upgrade, and — for money — the
amount and currency paid. **It carries no email address, no device identifier and
no IP address**, and it creates no person profile in PostHog. The identifier is
generated by this service and matches nothing PostHog or anyone else holds, so an
event says "a lifetime licence was sold for €99" and not who bought it.
`Service/test/analytics.test.mjs` asserts the exact set of fields that leave, and
that an address handed to it by mistake is dropped rather than sent.

The service also passes on, to the same PostHog project, each of the nine
product events described under "Product events, field by field" below, at the
moment it accepts and stores one. That is what puts the stretch between a
download and a first dictation on the same dashboard as the website's visits and
downloads. Each carries the event name, the **install's own random identifier**
as PostHog's distinct id, the qualifier the event has (one word from the fixed
sets printed below, or none), and the two version fields: the app version and
the macOS major and minor. It carries the same four things the app already sent
to the service and **nothing the service did not already hold**: no email
address, no device identifier, no licence identifier and no IP address, and it
creates no person profile. The install identifier is not the licence identifier
and is joined to neither, so a funnel event never meets a sale in PostHog except
as a count on the same chart. An event the service refuses, or rate-limits, is
not passed on. Turning product events off in Settings, Privacy stops them
before they reach the service, and therefore before they could reach PostHog.
`Service/test/events.test.mjs` asserts the exact set of properties that leave.

PostHog is a processor under a data processing agreement. The legal basis is
Art. 6(1)(f) GDPR — knowing how many trials and sales there are, and where
people stop before the first one, over time, is necessary to run a product sold
for money — and the events are deleted on the same terms as the website's own
PostHog events. The service refuses to send to any PostHog host outside the EU.

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
| The nine product events above, as rows carrying only the five fields named | Counting the funnel | 90 days, then deleted — `Service/src/events.js`, and a test asserts the sweep |

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

The app builds fifteen events about setting itself up and about the licensing
funnel. **Nine of them are sent. The other six are written to the local log and
go nowhere**, which is what every earlier version of this app did with all of
them — `docs/PHASE_8_DECISIONS.md` D7 recorded that decision and
`docs/REFINEMENTS.md` records reversing it, first for the three about the trial
and then for the six about setup.

| Event | Sent when |
| --- | --- |
| `installed` | The first launch, once |
| `model_download_started` | A launch starts fetching the 1.6 GB speech model |
| `model_ready` | The model is usable for the first time, with how long that took as one of four buckets |
| `model_failed` | Getting it did not work, with `network`, `storage` or `other` |
| `dictation_blocked_by_model` | You hold the hotkey while the model is still arriving |
| `microphone_denied` | macOS asked for the microphone and the answer was no |
| `trial_started` | Your first successful dictation — the moment the three ungated days start |
| `activation_requested` | You press **Send me a key** or **Send my key** |
| `paywall_shown` | The app puts the offers on screen, with which of the four reasons it did |

**The six about setup are sent at most once for each installation, ever.** That
is a promise about what this can be used for, not a detail. The speech model is
loaded every time the app starts, so an event sent whenever it became ready
would not be a funnel step at all: it would be a record, on a server, of when
this Mac opens Witness. The same is true of a refused microphone, which is
re-read every time the app comes forward. So the app remembers which of the six
it has already sent, as a list of their names in
`~/Library/Application Support/Witness/license.json` — the same readable file
that already knows when this installation happened — and sends nothing the
second time. `EntitlementServiceTests` asserts it, including across
a relaunch.

They go to `api.witnessmac.com`, which stores them for ninety days (see "What
the service stores") and passes each one on to PostHog's EU region, as described
under "What the service tells PostHog". Those are the only two places they ever
exist outside this Mac.

Each one is this, and nothing else:

```json
{"app_version":"0.3.0","event":"trial_started","install_id":"<a random UUID>","system_version":"15.0"}
```

Three events add a fifth field, `qualifier`, and each draws it from its own
fixed set of words:

- `paywall_shown`: `activationRequired`, `trialExpired`, `licenseExpired`,
  `updateRequired`;
- `model_ready`: `underOneMinute`, `underFiveMinutes`, `underFifteenMinutes`,
  `overFifteenMinutes` — a bucket and never a number of seconds, because a
  duration is a fact about one Mac on one connection and a bucket is all a
  count needs;
- `model_failed`: `network`, `storage`, `other` — no filename, no path, and no
  message from the system.

There is no sixth field, and
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
installed. Off means none of the nine is sent and nothing else about the app
changes — not the trial, not the dictation, not the licence.

Two of them can happen before you have read that sentence, and saying so is
part of keeping it honest: `installed` is sent when the app first starts, and
`model_download_started` when it begins fetching the speech model, which is also
at that first launch. The first-run screen carries the sentence and appears in
the same first minute, behind the language question — but it appears *beside*
those two events rather than before them. The other seven all follow something
you did. If that trade is not one you want, the switch turns the lot off and
nothing else changes.

**Why it is on by default, said plainly.** These events exist to answer two
questions: how many installations ever reach a first dictation, and how many
people stop at the wall rather than paying. The first one was unanswerable until
these events existed — downloads were being counted and first dictations were
not, so a person whose model never arrived and a person who never opened the app
looked identical. A count that only includes people who opted in is a count of
people who did not stop, which answers a different question. That is the reason, it is not a good enough
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
