# The activation service

The other half of `docs/PHASE_8.md`. It turns an email address into a signed
license key for one Mac, mails a copy, and counts the two Macs a license covers.

It is deliberately small — two endpoints, a webhook, and a health check — and it
is allowed to be, because Phase 6 made a license a signature rather than a phone
call. **The app never asks this service whether a license is valid.** It asks it
once, for a key, and verifies that key offline forever after. This service being
down means nobody new can activate; it does not mean a single paid copy stops
working.

## Shape

```
tools/
  set-secret.sh      set one secret, with the value never on a command line
  parity-fixture.mjs the committed fixture, from this source
  live-fixture.mjs   a fixture from a running deployment
src/
  worker.js     the router, and the health check
  activate.js   POST /v1/activate: the whole of what a person can be told
  release.js    POST /v1/devices/release: the key is the proof
  webhook.js    POST /v1/purchases/webhook: money becoming an entitlement
  providers.js  Paddle and Stripe, behind one shape
  token.js      the frozen payload, byte for byte
  signing.js    Ed25519, and the check that the secret matches the shipped app
  store.js      every row, and every question asked of one
  email.js      the address, normalized the same way the app validates it
  mailer.js     Resend or Postmark, behind one method
  http.js       JSON answers, bounded requests
schema.sql      the whole of what is stored
test/           node:test, over the real schema in an in-memory SQLite
```

No dependencies, and none intended. Everything it needs — Ed25519, base64,
SQLite in the tests — is in the platform, and a licensing service is the last
place worth taking a supply chain on.

## Running the tests

```bash
cd Service && npm test
```

Node 22 or newer (`node:sqlite`, and Ed25519 in WebCrypto). Nothing is installed
and nothing is downloaded.

To run the service itself, against a local D1 and the real Workers runtime:

```bash
npx wrangler d1 execute localdictation-licenses --local --file schema.sql
```

```bash
npx wrangler dev
```

`wrangler dev` reads secrets from `.dev.vars`, which is git-ignored and holds a
**throwaway** signing identity — a key issued locally verifies in nothing that
ships, which is the point. Generate one with the same code the tests use:

```bash
node -e 'import("./test/support/keys.mjs").then(async ({makeKeypair}) => { const k = makeKeypair(); const {writeFileSync} = await import("node:fs"); writeFileSync(".dev.vars", `LICENSE_SIGNING_KEY = "${k.privateBase64}"\nLICENSE_PUBLIC_KEY = "${k.publicBase64}"\nMAIL_PROVIDER = "none"\n`); console.log(k.publicBase64) })'
```

## Parity with the app

`LicenseKey.verify` in the app checks a signature over **the payload bytes as
they appear in the token**. A re-serialized payload with different key order
verifies against nothing, so the format is frozen in `docs/PHASE_8.md` and
proved in two directions:

```bash
npm run fixture   # regenerate Service/fixtures/parity.json
```

`LocalDictationTests/ActivationServiceParityTests` reads that file through the
shipping verifier on every run, and — where Node is installed — regenerates it
and compares byte for byte, so an issuer change nobody re-ran the generator for
fails in the app's test suite rather than in a customer's inbox.

That covers the source. It does not cover the **runtime**: everything here is
tested under Node, production is workerd, and Ed25519, base64 and JSON are three
places those could differ by a byte. So ask a running service for real keys and
read those through the verifier too:

```bash
node tools/live-fixture.mjs --url https://<host> --pair you@example.com:<32 hex>
```

That writes `fixtures/live.json`, which the same test picks up whenever it
exists and ignores when it does not. It is git-ignored: it describes one
deployment at one moment, and against production it holds real signed keys.

Do this once against a local `wrangler dev`, and once against the real
deployment before the first key goes to a stranger. It has been done locally:
one key of each kind, issued by workerd, verified through `LicenseKey.verify`.

The fixture is signed with a fixed throwaway seed. The production private key is
in one Workers secret and one file on one laptop, and appears nowhere here; a
test asserts the fixture does *not* verify against the shipped authority.

## Deploying

Cloudflare Workers and D1 (`docs/PHASE_8_DECISIONS.md`, D3).

```bash
npx wrangler d1 create localdictation-licenses
# put the id it prints into wrangler.toml
npx wrangler d1 execute localdictation-licenses --remote --file schema.sql

# The signing identity. This is the base64 in ~/.localdictation/license-signing-key,
# unchanged — the same identity Tools/licensekit.swift has been issuing with, so
# moving issuing here invalidates nothing already sold.
npx wrangler secret put LICENSE_SIGNING_KEY

# The mail provider's key (Resend or Postmark).
npx wrangler secret put MAIL_API_KEY

# The payment provider's webhook signing secret, once D2 is executed.
npx wrangler secret put WEBHOOK_SECRET

npx wrangler deploy
```

Then set `MAIL_PROVIDER`, `MAIL_FROM` and, if the provider needs it,
`MAIL_STREAM` in `wrangler.toml`.

`LICENSE_PUBLIC_KEY` is a plain var, not a secret: it is the public half, it is
in the app already, and it is here so `/v1/health` can answer the one question
no dashboard otherwise asks.

### Checking it before trusting it

```bash
curl -s https://<host>/v1/health
```

```json
{"status":"ok","database":true,"signing_key":true,"authority_match":true,"mail_provider":"resend"}
```

`authority_match` false means this deployment is signing with the wrong key. It
will look completely healthy from the outside and issue keys that verify on
nobody's Mac, which is why it is a health check and not a comment.

### Staging, and why there is no localhost path

`HTTPActivationBackend` reports itself unconfigured for a plain-HTTP endpoint
rather than sending an address in cleartext, so `http://localhost` is not a
staging plan and no "allow insecure in Debug" flag will be added — the one thing
that must never differ between the build that was tested and the build that
ships is which addresses it will send an email to.

Put a real certificate in front of a local run:

```bash
npx wrangler dev
```

```bash
cloudflared tunnel --url http://localhost:8787
```

Then point a Debug build at it by giving `ActivationEndpoint.production` the
tunnel's URL. That is a one-line change and it is deliberately not configurable
at runtime.

**There is no `[env.staging]` in `wrangler.toml`, on purpose.** It was there as a
placeholder with a fake database id, and its only effect was that every
`wrangler secret put` then demanded an `--env` flag to disambiguate — which is
exactly the kind of prompt somebody pastes a secret into by mistake. A staging
environment gets added when something actually needs one, with a real database
behind it.

One thing to know if that day comes: staging has to sign with the **production**
key. The app carries one authority in every configuration, so a key from a
service using a different one would be refused by the very build being tested.

## Operations

- One log line per issuance, carrying the key id and the kind. **Never the
  address.** A log that carries a customer's email is a log that has to be
  retained like the licence table.
- The failure that matters is silent: a mailer that stops delivering looks
  exactly like a quiet week. Alert on the issuance rate falling to zero, not on
  errors.
- Rate-limit counters are the only place an IP appears. They are swept after 24
  hours, by the request that comes after them.

## What is stored, and what is not

`schema.sql` is the whole answer, and `docs/PHASE_8.md` is where it was agreed.
Nothing content-derived is in it and nothing in this product could put it there:
the app's request has two fields, `device` and `email`, and a test in the app
fails if a third ever appears.

The license key itself is **not** stored. Ed25519 is deterministic, so the five
fields in `device_slots` reproduce the exact token that was issued — which is
what makes pressing the button twice return the identical key without this
service keeping one.

One column is not in that document's table: `mailed_at`. It is what makes
"pressing Send me a key twice mails one key" true, and what lets a key whose
first delivery failed be sent by the next press instead of being lost.

## Stripe

`docs/PHASE_8_DECISIONS.md` D2, executed: **Stripe, as merchant of record.**

In the dashboard, once:

1. One product with two prices — €99 one-off and €49 yearly.
2. A Payment Link for each. Copy the two URLs into `StoreFront` in the app, and
   the two `plink_…` ids into `PAYMENT_LINK_LIFETIME` and `PAYMENT_LINK_ANNUAL`
   — a Payment Link checkout sends **no line items** on the webhook, so the
   link id is the only thing in that payload that says which offer was bought.
   The price ids are optional and only read if a session ever arrives with its
   line items expanded.
3. Check the **product tax code**. The default this project was first offered,
   "Software as a service (SaaS) – business use", describes neither half of what
   this is: a downloaded binary that runs entirely on the buyer's Mac, sold to
   individuals. Pick a downloadable-software, personal-use code instead, and
   have whoever handles D5 confirm it. Leave "Tax included in price" on — the
   app says €99 and that is what the buyer should pay.
4. A webhook endpoint at `https://<host>/v1/purchases/webhook`. Its signing
   secret goes in `WEBHOOK_SECRET`, typed at the prompt and never on the command
   line:

   ```bash
   ./tools/set-secret.sh WEBHOOK_SECRET
   ```

   Use that rather than `wrangler secret put` directly. `put` takes the *name*
   as its argument and reads the value from stdin, which is one character away
   from two mistakes that both happened while this service was being set up: the
   value in a flag (`--env="whsec_…"`), which puts it in the shell history and
   in wrangler's log; and the value as the *name*, which puts it in
   `wrangler secret list` in plain text and leaves `WEBHOOK_SECRET` unset, so
   every real purchase is rejected while everything looks configured.

   The script refuses both, checks the value's shape, and prints the names
   afterwards so a mistake is visible immediately. Any value that has reached an
   argument list is public: roll it on the endpoint's page. **Set its API version to the newest
   one**, not the account's default: the version decides the payload's shape,
   Payment Links did not exist before 2021, and a session rendered by an older
   version carries no `payment_link` — which is the only thing in that payload
   that says the sale was ours. Every sale would go unattributed, and the app
   would look like it simply never activated anybody.

   When a sale is not attributed the log line says what identifiers it did see,
   which is how the two causes are told apart: `saw: ["plink_…"]` is another
   product's sale, and `saw: []` with `has_email: true` is this version
   mistake.

There is **no "collect customer email" option**, and there is nothing to turn
on: Checkout always collects an address, because it has to send a receipt.
`customer_details.email` is therefore always present on
`checkout.session.completed`, which is what makes "the address is the licence"
safe to build on.

Select exactly these events:

| Event | What it does |
| --- | --- |
| `checkout.session.completed` | Creates or extends the licence on the buyer's address |
| `invoice.paid` | Extends an annual on renewal, a year later |
| `charge.refunded` | Marks the licence dead for future issuance |
| `charge.dispute.created` | The same |

`invoice.payment_succeeded` fires for the same money as `invoice.paid` and
carries a different event id, so idempotency cannot stop both from being acted
on — an annual would grow by two years for one payment. The code refuses it
outright, so selecting it by accident is harmless. `customer.subscription.deleted`
is deliberately not acted on: a cancelled annual runs to the date it was paid
for.

### One account, two products

Stripe delivers **every** event on an account to **every** webhook endpoint.
There is no per-product endpoint and no filter in the dashboard, so this account
selling something else as well is not a configuration detail — it is a
correctness requirement on this code. It is met in two places and neither of
them is the customer's address:

- **A sale** is recognised by the Payment Link it came through. A session for
  any other link matches neither configured id, `parse` returns `null`, and the
  webhook answers `202` and does nothing.
- **Everything after the sale** — a renewal, a refund, a dispute — is matched to
  a licence through `provider_refs`, a table of every identifier the provider has
  used for it: the checkout session, the payment intent, the subscription, each
  invoice and charge. An event naming none of them belongs to something else.

The address is deliberately not a fallback anywhere in that path. One person can
buy two products from one account with one email, and matching a refund by
address would let a refund for the other product mark this one's licence dead.
There are tests for exactly that.

The consequence worth knowing: **a licence created outside this flow has no
refs**, so a refund for it cannot be matched and is logged rather than applied.
That is the intended direction for the error to fall — doing nothing is
recoverable by hand, and killing a stranger's licence is not.

### The renewal, and the mail that matters

A key carries the date it was issued against, so a subscriber's key still
expires on the old date even after the licence does not. `invoice.paid`
therefore mails one instruction — press **Send my key** — and the app warns two
weeks ahead as well. Without that mail a paying subscriber is locked out on
their renewal day, which is the worst possible day for it.

## The one thing here that has not been run for real

`src/providers.js` reads each provider's documented payload: which field the
buyer's address is in, which one names the price, and what a refund looks like.
Those paths need an account to confirm, and there is not one yet — so `parse`
returns `null` rather than guessing when it cannot find an address, the webhook
answers `202` and logs it, and the provider stops retrying while somebody looks.

Send one test event from the provider's dashboard before the first real sale,
and check that `/v1/purchases/webhook` answers `{"applied":true}`. Everything
else in this service is covered by `npm test`; this is the one thing a test
cannot know.

## The endpoints

| | | |
| --- | --- | --- |
| `POST /v1/activate` | The one call the app makes. Contract frozen in `docs/PHASE_8.md` | built |
| `GET /v1/health` | Database, signing key, and whether that key matches the app | built |
| `POST /v1/devices/release` | Frees one of the two Macs. Possession of the key is the proof | built |
| `POST /v1/purchases/webhook` | Provider-signed, idempotent on the event id | built; needs D2's account |

The order is `docs/PHASE_8.md`'s: the trial path first, because it is the one a
stranger walks and the only one that needs nothing bought, decided, or signed up
for.
