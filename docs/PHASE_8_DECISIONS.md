# Phase 8 — D1 to D7, decided

`docs/PHASE_8.md` says none of these are engineering questions and every one of
them changes what gets built. This file is the answers, so that the code below
them has something to point at.

Two of them cost money and one costs a lawyer. **None of them blocks writing the
service** — they block deploying it, which is why `Service/` exists and is
tested while D1 to D4 are still open. What each one actually gates is in the
last column.

| # | Decided | Price | Gates |
| --- | --- | --- | --- |
| D1 | Apple Developer Program membership — **bought, enrolled** | €99/year | Nothing any more. The certificate is the next step, not the decision |
| D2 | **Stripe, as merchant of record** — settled: the account already exists for another product | 3.5% per transaction on top of card fees, per the Managed Payments toggle | The three `StoreFront` URLs, which are now the only remaining code change |
| D3 | Cloudflare Workers + D1, signing key in Workers Secrets | €0 at this volume | `ActivationEndpoint.production` |
| D4 | Resend, on the product domain, SPF and DKIM before the first key | €0 to 3,000 mails/month | Whether a key that was issued is a key that arrived |
| D5 | Einzelunternehmen, Impressum and Widerruf with the digital-goods waiver | An afternoon and an accountant | Selling in Germany at all |
| D6 | Lifetime = the purchased major version and every minor update to it | Nothing now; a version table later | The word "lifetime" meaning the same thing to buyer and seller |
| D7 | Transmit nothing in the first release | Nothing | Nothing. This is the one item safe to leave |

## D1 — the membership

**Done.** €99 a year was never the decision; the decision was that there is no
way to hand this app to a stranger without it.
Developer ID certificates are not issued to free accounts, notarization needs
one, and an un-notarized `.dmg` opens with a dialog that says the developer
cannot be verified — on a product whose entire pitch is that it does not send
your voice anywhere.

It also buys back something the README already complains about: macOS keys the
Accessibility grant to the code signature, so every unsigned rebuild loses it.
A stable Developer ID signature means the grant survives updates.

## D2 — who takes the money

**Stripe, as merchant of record.** The condition this decision was waiting on —
availability for this account — is met: the account exists and is already in use
for another product, which also means the identity and payout side is done
rather than pending.

Both candidates were merchants of record, which is the property that matters:
they own the VAT problem, including the one-stop-shop filing that makes selling
a €49 licence to a customer in another EU country an ordinary act rather than a
tax registration. `docs/MONETIZATION.md` priced the fee difference at about €1
on a €99 sale, so it was never the deciding factor and it is not one now. The
dashboard states Managed Payments as 3.5% per transaction, which on €99 is about
€3.50 before card fees — worth writing down, because it is the number the price
was set against.

Paddle stays implemented in `Service/src/providers.js`. It costs one file, it is
tested, and it is what makes changing this decision a change to
`PAYMENT_PROVIDER` rather than a rewrite.

**One thing to confirm in the dashboard rather than assume**: Managed Payments
has to be enabled for *this* product, not only for the account. Selling software
licences is inside its scope, but the switch is per-product, and a checkout that
runs without it makes this project the merchant of record and hands back the VAT
problem the decision existed to avoid.

**The account sells another product too**, and that is a correctness
requirement rather than a detail: Stripe delivers every event on an account to
every webhook endpoint, with no per-product filter anywhere. So a sale is
recognised by the Payment Link it came through, and everything after a sale is
matched to a licence through identifiers this service recorded itself. The
customer's address is deliberately not a fallback: one person can buy both
products with one email, and matching a refund by address would let a refund for
the other product mark this one's licence dead. It did, until it was tested.

Three payload facts about Stripe specifically shaped the code, and all three were
bugs before they were noticed:

- A **Payment Link** checkout sends no line items on the webhook, so the price
  id simply is not in the event. The link's own id is, and we created both
  links, so `PAYMENT_LINK_LIFETIME` and `PAYMENT_LINK_ANNUAL` are how an offer
  is identified on that path.
- An **annual is a subscription**, and its renewal a year later arrives as
  `invoice.paid` rather than as another checkout. Without reading that, a
  paying subscriber's licence would have quietly lapsed on its first renewal.
- **A subscription's charge names nothing that was stored at checkout** — a
  payment intent this service has never seen. Which is why every identifier a
  purchase carries is recorded when it happens, rather than one of them.

## D3 — where it runs

**Cloudflare Workers, D1 for the table, the signing key in Workers Secrets.**

The whole service is two endpoints and a table, and this is the option where
that sentence stays true: no server to patch, no container to rebuild, a free
tier this will not leave for a long time, and a database that is a `.sql` file
in the repository.

The signing key deserves its own sentence. It is the base64 in
`~/.localdictation/license-signing-key`, unchanged, put into a Workers secret —
so moving issuing from a laptop to a service invalidates **nothing** already
issued, and `LicenseAuthority.productionPublicKeyBase64` never changes. That
file is the product's identity: losing it means no further key can be issued for
a license already sold, and replacing it invalidates every key ever issued.
Back it up somewhere that is not a laptop.

`/v1/health` reports whether the secret in a deployment actually matches the
public key the shipped app carries, because the failure it prevents is silent:
a wrong secret issues keys that verify on nobody's Mac while every dashboard
stays green.

## D4 — the mail

**Resend**, on the product domain, with SPF and DKIM set up before the first key
is ever sent.

Postmark has the better deliverability reputation for transactional mail and is
the swap if Resend disappoints; `Service/src/mailer.js` is one method behind an
environment variable, so that swap is a variable rather than a deploy.

The thing worth being careful about is not the provider. It is that the reply to
`POST /v1/activate` unlocks the app and the mail is only what the user still has
when they replace the Mac — so a mailer having a bad day must not fail an
activation. It does not: delivery is recorded separately, and the next press of
the button sends what the last one could not.

Transactional only. Marketing to an address collected here needs its own
consent, and in Germany that is §7 UWG rather than a formality.

## D5 — the legal half

Out of scope for code, and it blocks selling in Germany regardless of what the
code does. Einzelunternehmen, an Impressum on the product site, and a Widerruf
that includes the digital-goods waiver — the sentence a buyer agrees to that
lets a licence key be delivered immediately instead of after fourteen days.

The one place this reaches the code is retention: the provider order id is kept
"whatever the accountant says invoices need". Until there is an accountant, it
is kept.

## D6 — what "lifetime" means

**The purchased major version and every minor update to it.** This is
`docs/PRODUCT_SCOPE.md`'s recommendation and there is no better one: it is the
only reading under which the seller can keep shipping and the buyer can tell,
before paying, what they are buying.

The payload already carries `issued`, and `License.issuedAt` is what a rule like
this reads. What it needs beside it is the date each major version was released
— a table in the app, not a call to anything — so that a lifetime key issued
before 2.0 keeps 1.x working forever and says, plainly, what 2.0 would cost.
That is built in `LifetimeUpdatePolicy`.

The word "lifetime" is never used in the app for a duration of time. It means a
version, and the offer says so.

## D7 — the events

**Ship the first release transmitting nothing.** `LocalOnlyTelemetryService`
keeps building the envelope and writing it to the local log, exactly as it does
today.

There is no funnel worth measuring before there are users, and consent asked for
a collector that does not exist yet is consent asked for nothing. The day it is
worth it, what turns on is a transport — the events, their allowlist, and the
test that no content can reach them all exist already.
