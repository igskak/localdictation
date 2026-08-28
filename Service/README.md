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
src/
  worker.js     the router, and the health check
  activate.js   POST /v1/activate: the whole of what a person can be told
  token.js      the frozen payload, byte for byte
  signing.js    Ed25519, and the check that the secret matches the shipped app
  store.js      every row, and every question asked of one
  email.js      the address, normalized the same way the app validates it
  mailer.js     Resend or Postmark, behind one method
  http.js       JSON answers, bounded requests
schema.sql      the whole of what is stored
tools/          the parity fixture generator
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

Either deploy the staging environment:

```bash
npx wrangler deploy --env staging
```

or put a real certificate in front of a local run:

```bash
npx wrangler dev
cloudflared tunnel --url http://localhost:8787
```

Either way, point a Debug build at it by giving `ActivationEndpoint.production`
the URL. That is a one-line change and it is deliberately not configurable at
runtime.

Note that staging signs with the **production** key on purpose: the app carries
one authority in every configuration, so a key from a staging service that used
a different one would be refused by the very build being tested.

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

## The endpoints

| | | |
| --- | --- | --- |
| `POST /v1/activate` | The one call the app makes. Contract frozen in `docs/PHASE_8.md` | built |
| `GET /v1/health` | Database, signing key, and whether that key matches the app | built |
| `POST /v1/devices/release` | Frees one of the two Macs. Possession of the key is the proof | not yet |
| `POST /v1/purchases/webhook` | Provider-signed, idempotent on the event id | waits on D2 |

The order is `docs/PHASE_8.md`'s: the trial path first, because it is the one a
stranger walks and the only one that needs nothing bought, decided, or signed up
for.
