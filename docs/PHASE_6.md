# Phase 6 — licensing that a paid user never has to justify

## Objective

Turn a working utility into a product someone can buy, without giving up the
one property that made it worth building.

```text
install
  -> dictate: the first five utterances, or the first 24 hours, ask for nothing
  -> email  -> a signed key for this Mac -> fourteen full days
  -> buy    -> a signed key for this Mac -> annual, or forever
                 |
                 +-> every check happens on this Mac, offline, against a
                     signature nobody outside can forge
```

The phase is the second half of `docs/ARCHITECTURE.md`'s last entry — activation,
trial, paywall, entitlements, product telemetry, and the release path. What it
delivers is the whole local side of that: the rules, the key format, the gate,
and the interface. What it deliberately does not deliver is a running service to
talk to, because there is not one yet, and the parts that need one are named
below rather than stubbed into looking finished.

## The decisions worth reading before the code

### A license is a signature, not a phone call

The app carries an Ed25519 public key and verifies a pasted key locally. There
is no activation server in the checking path at all: a bought copy works on a
plane, behind a corporate proxy, at a customer site, and in ten years when this
project's servers are gone.

The cost is stated rather than hidden. **A key cannot be revoked remotely.** A
refunded or leaked key keeps working until it expires, and a lifetime key keeps
working forever. For a desktop utility sold once to individuals that is the
right side of the trade — the alternative is a product that stops working when
a server does, which is the thing this product exists not to be.

### The key names the Mac, so "two Macs" means something

The payload carries a device identifier, and a key issued for one Mac is refused
on another with a sentence that says so. The identifier is
`SHA-256(salt || IOPlatformUUID)`, truncated to 128 bits: stable on this Mac,
useless anywhere else, and not reversible to a serial number. Counting the two
is the issuer's job; making the count mean anything is this.

### The trial clock only moves forward

`UsageRecord.furthestSeenAt` holds the furthest point in time the app has ever
been at, and every elapsed measurement runs from `max(now, furthestSeenAt)`.
Setting the clock back returns nothing. Setting it forward is left alone: a user
who does that has shortened their own trial, and second-guessing it would mean
second-guessing every daylight-saving change and time-zone move.

### The record on disk is plain, and that is a decision

`license.json` sits beside `glossary.json`, unobfuscated, six fields, readable
in a text editor. Anything the app could do to a local file a determined user
can undo in an afternoon; what obfuscation actually buys is a product that lies
to its owner about what it stores. The honest defence is structural: **editing
the record can hand someone a few more days of trial, and can never hand them a
license**, because a license is a signature.

### The lock is a precondition of dictation, not a phase of it

`RecordingState` gains `.locked`, for the same reason it has
`.needsPermission`: this machine is what decides whether a hotkey press opens a
microphone, and a precondition it cannot see is one that gets forgotten in one
of the paths. The lock is stored *beside* the state rather than inside it, which
is what lets both of these be true at once:

- A trial that runs out mid-utterance **never takes the sentence with it.** The
  recording finishes, the transcript arrives, the text goes into the document,
  and the app locks after that.
- The press after it is refused, whatever the microphone says.

The second is worth spelling out. `.authorizationResolved` fires on every
activation of the app; if it could leave `.locked`, clicking the menu bar would
unlock the product. It cannot, and a test says so.

### What the window is spent on

Five dictations, and a dictation is *text the user received*. A press that
recognized nothing costs nothing — `docs/PHASE_4_COMPATIBILITY.md` records two
utterances of nine and ten seconds that came back empty on a real Mac, and
charging a fifth of someone's window for that would be indefensible. The count
is taken when the result is non-empty, before insertion, because whether the
text then lands in a document or on the clipboard is not the user's doing.

### Telemetry is a type, not a discipline

`TelemetryEvent` is an enum whose only optional field is drawn from fixed sets
of strings. There is no free-form parameter anywhere in it, so there is nothing
for a transcript to be passed to — the privacy boundary is enforced by the
compiler rather than by whoever writes the next call site. The complete list:

| Event | Qualifier | When |
| --- | --- | --- |
| `installed` | — | first launch, when the record is created |
| `trial_started` | — | first successful dictation |
| `activation_requested` | — | the user pressed "Send me a key" |
| `activation_succeeded` | — | a key came back and verified |
| `activation_failed` | reason | it did not |
| `license_accepted` | kind | a key verified on this Mac |
| `license_rejected` | reason | a key did not |
| `paywall_shown` | trigger | the Mac became locked |
| `checkout_opened` | offer | the user went to buy |
| `entitlement_lapsed` | kind | a dated license reached its date |

Every event travels with exactly four other fields: `app_version`,
`system_version` (major and minor only — a rare build number is an identifier),
`install_id` (random, made at install, **not** derived from the Mac and
therefore not joinable to the device hash a license carries), and the qualifier
above when there is one.

**Nothing is transmitted today.** `LocalOnlyTelemetryService` builds the
envelope and writes it to the local log. The day a collector exists, what turns
on is a transport, not a design.

### The two things this phase does not have

- **An activation service.** `UnconfiguredActivationBackend` refuses and names
  the other way in, rather than pretending to succeed. A stub that silently
  worked would make every activation test pass and ship the product broken. The
  contract it will implement is one call: email plus device hash in, a signed
  key out, and nothing else in either direction.
- **A checkout.** `docs/PRODUCT_SCOPE.md` makes Stripe Managed Payments
  conditional on availability and product eligibility in the project account,
  and neither is confirmed. `StoreFront`'s two URLs are `nil`, the Buy buttons
  are disabled, and the paywall says checkout is not open yet. Filling in those
  two constants is the whole of what turns buying on.

## Issuing keys

The private key never enters the repository and never enters the app.

```sh
swift Tools/licensekit.swift init
# prints the line to paste into LicenseAuthority, and writes the private half
# to ~/.localdictation/license-signing-key

swift Tools/licensekit.swift issue --device <id> --email you@example.com --kind lifetime
```

The Mac's identifier is in **Settings → License → This Mac**.

`LicenseAuthority.productionPublicKeyBase64` is empty until `init` has been run
and its output pasted in, which means **a development build accepts no license
at all** and says so in Settings. That is deliberate: a build that licensed
itself would make the whole path untested.

The tool writes the token's JSON by hand — it is the server side, and it will
one day be a server. `LicenseIssuerToolTests` runs it for real, with a signing
key in a throwaway home directory, and reads the result back through the
shipping verifier, so a renamed field fails here rather than in a customer's
inbox.

## Acceptance criteria

- The first five dictations, or the first 24 hours from the first one, need no
  email and no key. Both halves of "whichever comes first" are asserted.
- The dictation that closes the window is still delivered in full.
- A locked Mac never opens the microphone, and re-reading microphone
  authorization cannot unlock it.
- A trial or license expiring mid-utterance never costs the user that utterance.
- A key verifies offline; an edited payload, a key from another authority, and a
  key for another Mac are each refused with a sentence that says what to do.
- A token that stops verifying is discarded rather than shown as a license.
- A dictation that recognized nothing is not counted.
- The record on disk holds six fields and nothing else.
- Every product event's payload keys are inside the allowlist, and no event can
  carry content.
- The app with no licensing service configured gates nothing — every other test
  in the suite depends on that.

```sh
xcodebuild test -project LocalDictation.xcodeproj -scheme LocalDictation -destination 'platform=macOS,arch=arm64'
```

## What is still open

- The activation service, and with it the counting of the two Macs a license
  covers. Until it exists, activation is a key issued by hand.
- Checkout, which waits on the Stripe account decision recorded in
  `docs/PRODUCT_SCOPE.md`.
- Signing, notarization, and updates: `docs/PHASE_6_RELEASE.md`, none of it run.
- The exact lifetime update policy. `docs/PRODUCT_SCOPE.md` recommends the
  purchased major version and all its minor updates. The payload carries the
  issue date, which such a rule could be written against; nothing in the app
  reads it that way yet.
