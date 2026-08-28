# Phase 8 — the licensing flow becomes a sale

## Objective

Close the loop that Phase 6 opened. Today a stranger who installs this app
dictates five times, is told to activate, and finds that there is nothing to
activate against and nothing to buy: `ActivationEndpoint.production` is `nil`,
both `StoreFront` URLs are `nil`, and the only way past the wall is a key issued
by hand from a laptop. Phase 8 is the work that makes the sentence "add your
email and it keeps working" true without a human in the loop.

```text
install -> dictate -> the wall
                        |
     +------------------+------------------+
     |                                     |
  email -> POST /v1/activate            buy -> checkout -> webhook
     |        trial key, 14 days             |    license on the address
     +------------------+------------------+
                        |
              email -> POST /v1/activate
                        annual or lifetime key for THIS Mac
```

The shape above carries the one non-obvious fact of this phase: **a paid key
cannot be issued at checkout.** A key names a Mac, and a browser does not know
which Mac. So buying creates an entitlement against an *address*, and the same
one endpoint turns that address into a key the next time the app asks. There is
one call, and what it returns depends on what the address owns.

## What already exists, so it is not rebuilt

Phase 6 delivered the whole local half, and the branch that produced this
document added the client half of the network call:

| Piece | Where | State |
| --- | --- | --- |
| Offline verification, key format, authority | `LocalDictation/Services/Licensing/LicenseKey.swift` | Done, tested |
| Trial and ungated rules, clock-tamper defence | `Services/Licensing/EntitlementPolicy.swift` | Done, tested |
| The gate, the counting, the record | `Services/Licensing/EntitlementService.swift` | Done, tested |
| Key issuing, by hand | `Tools/licensekit.swift` | Done, tested end to end |
| Settings → License, the paywall, the lock in the menu | `Features/Licensing/`, `Features/MenuBar/` | Done |
| **The activation client** | `Services/Licensing/HTTPActivationBackend.swift` | Done, tested against a stub server |
| **The warning before the wall** | `Features/Licensing/EntitlementNotice.swift` | Done, tested |
| **Fetching a key bought elsewhere** | `LicensePresentation.offersKeyRetrieval` | Done, tested |
| Product events | `Services/Telemetry/ProductTelemetryService.swift` | Built; transmitted nowhere |

So the app is already able to make the call. What does not exist is something
to call, something to buy, and a signature Gatekeeper will accept.

## Decisions before code

None of these are engineering questions, and every one of them changes what
gets built. They belong at the top of the first session that picks this up.

| # | Decision | Recommendation | Consequence if deferred |
| --- | --- | --- | --- |
| D1 | Apple Developer Program membership, €99/year | Buy it first — everything downstream waits on it | No Developer ID, no notarization, no `.dmg`. `docs/GTM.md` §7 blocker 1 |
| D2 | Payment provider and merchant of record | Stripe Managed Payments if the account is eligible; otherwise Paddle. `docs/MONETIZATION.md` prices the difference at about €1 on a €99 sale, so this is an availability question, not an economics one | No checkout URLs, no webhook shape, no VAT handling |
| D3 | Where the service runs, and where the signing key lives | Cloudflare Workers + D1, key in Workers Secrets; the whole service is two endpoints and a table | Nothing to point `ActivationEndpoint.production` at |
| D4 | Transactional mail | Postmark or Resend on the product domain, SPF/DKIM set up before the first key is sent | Keys land in spam, which reads to the user as a broken product |
| D5 | Legal entity, Impressum, Widerruf | Out of scope for code; blocks selling in DE regardless | `docs/GTM.md` §7 blockers 6 and 8 |
| D6 | The lifetime update policy | `docs/PRODUCT_SCOPE.md`'s recommendation: the purchased major version and all its minor updates. The payload already carries `issued`, which such a rule reads | The word "lifetime" means something different to the buyer and the seller |
| D7 | Whether product events are transmitted at all, and under what consent | Ship the first release transmitting nothing; decide once there is a funnel worth measuring | Nothing — this is the one item that is safe to leave |

## The wire contract, frozen

The client is written and tested against exactly this. Changing it means
changing `HTTPActivationBackend` and `HTTPActivationBackendTests` in the same
commit, and the service and the app do not have to be released together, so
prefer adding a field the client ignores over changing one it reads.

### Request

```http
POST <ActivationEndpoint.production>
Content-Type: application/json
Accept: application/json
User-Agent: LocalDictation

{"device":"<32 lowercase hex characters>","email":"<address as typed>"}
```

Two fields, and `HTTPActivationBackendTests.testTheRequestCarriesTheEmailTheDeviceAndNothingElse`
fails if a third ever appears. The user agent deliberately carries no version:
the privacy policy lists what is sent, and an app build plus an OS build are not
on that list. HTTPS only — a plain-HTTP endpoint makes the backend report
itself unconfigured rather than sending an address in cleartext. Do not answer
with a redirect; keep it one origin.

### Answers

| Status | Body | What the user is told |
| --- | --- | --- |
| 200 | `{"key":"LD1.…"}` | Nothing — the key is verified and stored, and the app unlocks |
| 400 | `{"error":"invalid_email"}` | The address does not look complete |
| 409 | `{"error":"device_limit"}` | This license already covers two Macs; release one |
| 400/401/403/404/410/422 | `{"error":"…","message":"…"}` | The `message`, verbatim, if there is one — one line, 200 characters, control characters stripped by `ServerMessage` |
| 429 | anything | "It is asking us to wait a moment" — temporary, dictation unaffected |
| 5xx | anything | "It answered with an error" — temporary, dictation unaffected |

The client refuses a 200 whose body is not a key that starts with `LD1.`, and
refuses any reply over 8 KB, so a captive portal or a proxy error page can never
be stored as a license.

### The token, byte for byte

The service issues what `Tools/licensekit.swift` issues. `LicenseKey.verify`
checks the signature over **the payload bytes as they appear in the token**, so
the service must sign exactly the bytes it base64url-encodes — a re-serialized
payload with different key order verifies against nothing.

```text
LD1.<base64url(payload JSON)>.<base64url(Ed25519 signature over those bytes)>
```

base64url, no padding, no line breaks. The payload is compact JSON with keys in
lexicographic order and no whitespace:

```json
{"device":"<hex>","email":"<address>","expires":1731628800,"id":"<uuid>","issued":1700092800,"kind":"trial"}
```

- `kind` is `trial`, `annual`, or `lifetime`.
- `issued` and `expires` are **whole** seconds since the epoch. A fractional
  value encodes differently in Swift and in JavaScript, and the signature is
  over the bytes.
- `expires` is **omitted entirely** for `lifetime` — not `null`. Swift's encoder
  omits a nil optional, and `LicenseKey` refuses a lifetime key that carries a
  date and a dated key that does not.
- `expires` must be greater than `issued`.
- `device` is the value from the request, unchanged.

**Parity is a test, not a hope.** Before the service issues a key to anyone,
have it produce one key of each kind into a fixture file and add a test beside
`LicenseIssuerToolTests` that reads them through the shipping `LicenseKey.verify`.
A renamed field or a stray space fails there rather than in a customer's inbox.

## The service

Two endpoints and a webhook. It is deliberately small: everything hard about
licensing in this product was made a signature in Phase 6 so that this side
could stay a table and a mailer.

### `POST /v1/activate`

1. Trim the address; lowercase it for lookup. Reject an address without a
   plausible shape → `400 invalid_email`. The client already refuses the
   obviously incomplete ones, so this is the second gate, not the first.
2. Rate-limit per address, per device, and per IP → `429`.
3. Find the strongest live entitlement on that address: lifetime, then an
   unexpired annual, then an unexpired trial.
4. **No entitlement** → issue a trial, unless this address or this device has
   already had one: a second trial is `422` with a message that names the
   offers. `expires = now + 14 days`. The app measures its own fourteen days
   from the first dictation and the service does not know that date; a user who
   activates late therefore gets slightly more than fourteen days of dictation,
   which is the right way round for that error to fall.
5. **Device slot.** If this device is already registered against the license,
   re-issue the same key and return `200` — the call is idempotent, and a user
   who presses the button twice must not spend their second Mac on it. If the
   license already has two live devices → `409 device_limit`.
6. Issue the key, return it, **and mail it.** The reply unlocks the app; the
   mail is what the user still has when they replace the Mac.
7. Transactional mail only. Marketing to that address later needs its own
   consent — in Germany, §7 UWG, and `docs/MONETIZATION.md` says why that is
   not a formality.

### `POST /v1/devices/release`

Body `{"device":"…","key":"LD1.…"}`. Verify the signature server-side, verify
that the key names that device and belongs to a live license, then mark the slot
released. Possession of the key *is* the proof — there is nothing else the app
holds, and an endpoint that frees a slot on an address alone lets anyone with a
guessable email evict a stranger's Mac. Idempotent, and rate-limited.

The app's existing "Remove from this Mac" button becomes the caller, when an
endpoint is configured. Removing locally must keep working when the call fails:
the local half is the user's, and a server having a bad day is not a reason to
strand them.

### `POST /v1/purchases/webhook`

Provider-specific and signature-verified. Idempotent on the provider's event id
— every provider re-delivers. It creates or extends the license on the address
the buyer used, and mails them one instruction: open the app, Settings →
License, type that address, press **Send my key**. That is the sentence the
whole "a key names a Mac" decision costs, and it belongs in the purchase email
rather than being discovered.

Refunds and chargebacks mark the license dead for *future* issuance. **An
already-issued key keeps working** — Phase 6 chose an offline check with its
eyes open, and this is the bill for it. Do not build a revocation check into the
app to fix this; it would trade the product's central promise for a rounding
error in fraud.

### Data, and what is not stored

| Stored | Why | Retention |
| --- | --- | --- |
| Normalized email | Identity of a license | Life of the license |
| Device hash (32 hex) | The two-device limit | Life of the license, or until released |
| Kind, issued, expires, key id | What was issued | Life of the license |
| Provider order id | Reconciling a payment | Whatever the accountant says invoices need — flag D5 |
| IP, in a rate-limit counter | Abuse | 24 hours, counter only |

Nothing content-derived appears above, and nothing in this product can put it
there: the app has no field to send it in. The device hash cannot be turned back
into a serial number, and the `install_id` in a product event is generated
separately so it cannot be joined to it.

A deletion request erases the address and keeps an anonymized order row. Say so
in the privacy policy, along with the consequence — no further keys for that
address.

### Health and operations

`GET /v1/health`, a log line per issuance that carries the key id and never the
address, and an alert on the issuance rate falling to zero. The failure mode
that matters is silent: a mailer that stops delivering looks exactly like a
quiet week.

## What remains in this repository

Small, and mostly one line each — which is the point of doing the client half
first. Struck through as they land; the two that are left both wait on money
rather than on code.

1. ~~`ActivationEndpoint.production` — the URL.~~ Still `nil`, and it stays that
   way until there is a deployment to name. Everything behind it is built and
   tested; `Service/README.md` has the staging recipe and the one-line change.
2. `StoreFront.lifetimeCheckout`, `annualCheckout`, `websiteURL` — three URLs,
   after D2. **The only remaining code change, and it is three constants.** The
   Buy buttons enable themselves, and the webhook that answers them is written.
3. ~~"Remove from this Mac" calls `/v1/devices/release` when configured.~~ Done.
   The service is told first, because the key is the only proof this Mac holds,
   and the local removal happens whatever the answer was.
4. ~~The lifetime update rule, after D6.~~ Done — `LifetimeUpdatePolicy`. It
   decides nothing today, because there has only ever been one major version,
   and a test says so.
5. A transport for `ProductTelemetryService`, after D7 — which says not yet, and
   for the first release that is the whole of the work.
6. ~~The privacy policy row for the activation call.~~ Done — `docs/PRIVACY.md`,
   with `PrivacyDisclosureTests` parsing the documented request body and
   comparing it to the one the encoder produces.
7. `docs/PHASE_6_RELEASE.md`, executed rather than written. Waits on D1.

Two things not on the original list turned out to be part of it:

- **A locked Mac was opening the microphone.** `.hotkeyPressed` is accepted by
  the state machine while locked — it transitions to `.locked`, which announces
  the wall — and the capture path read that acceptance as permission. The test
  that was meant to catch it asserted the start count synchronously, and capture
  starts from a task, so it asserted that the task had not run yet.
- **Nothing appeared when a press was refused.** The whole wall lived in the
  menu and in Settings, so a stranger pressed the key, got nothing, and
  concluded the app was broken. A refused press now opens the License page in a
  window, and only a refused press does.

### Testing against something before there is something

The client refuses plain HTTP, so `http://localhost` is not a staging plan. Use
a tunnel with a real certificate (`cloudflared tunnel`) or deploy the service to
a staging hostname and point a Debug build at it. Do not add an "allow insecure
in Debug" flag: the one thing that must never differ between the build that was
tested and the build that ships is which addresses it will send an email to.

## Where this stands

| Criterion | State |
| --- | --- |
| A stranger activates, nobody at this end touches anything | Built end to end; unproven until there is a deployment |
| Second Mac issued, third refused, releasing lets it in | `Service/test/release.test.mjs`, and the endpoint the app calls |
| Pressing "Send me a key" twice mails one key, one slot | `Service/test/activate.test.mjs` |
| A service key verifies through `LicenseKey.verify`, all three kinds | `ActivationServiceParityTests`, on every run, plus a byte-for-byte drift check where Node is present |
| Buying then "Send my key" unlocks that Mac | `Service/test/webhook.test.mjs`; the field paths need one real event from the provider |
| No network: told, and dictation unaffected | Phase 6, unchanged |
| The service stores nothing outside the table | `schema.sql`, asserted by a test that reads `PRAGMA table_info` |
| Notarized Developer ID build | Waits on D1 |

## Acceptance criteria

- A stranger installs the release build, dictates five times, types an address,
  and keeps dictating. Nobody at this end touches anything.
- The same address on a second Mac gets a second key; a third Mac is refused
  with the sentence about two Macs, and releasing one of the first two lets the
  third in.
- Pressing "Send me a key" twice mails one key and spends one device slot.
- A key produced by the service verifies through `LicenseKey.verify` in a test
  that runs in CI, for all three kinds.
- Buying, on an expired trial, followed by "Send my key" on the address used at
  checkout, unlocks that Mac.
- A user with no network is told the service could not be reached, and their
  dictation is unaffected until the window closes.
- The service stores nothing outside the table above, and the request still
  carries two fields.
- `spctl -a -vvv -t install LocalDictation.app` reports a notarized Developer ID
  build, and the app opens on a Mac that has never seen it.

## Order

1. **D1–D4.** Buy the membership, settle the provider, pick the host, set up
   the mail domain. Nothing below starts cleanly without these.
2. **The service, trial path only**, with the parity test. Point a Debug build
   at it and activate a real Mac.
3. **Release path** — `docs/PHASE_6_RELEASE.md` end to end, including the
   first-run measurement on a clean Mac that has never downloaded the model.
4. **Checkout and the webhook**, then the three `StoreFront` URLs.
5. **Device release**, then the lifetime rule, then telemetry if D7 says so.

Steps 2 and 3 are independent and are the two that unblock everything else.
