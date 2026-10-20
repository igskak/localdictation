# The paid-entry experiment

Written 20.10.2026. The decision is `docs/PHASE_8_DECISIONS.md` D8; this file is
what exists, what is still switched off, and the order to switch it on.

## What is being tested

Whether an ad visitor who is asked to pay first converts better than one who is
asked to download. As of 18.10 the free path had 7 real first dictations from
about 21 ad downloads and 0 sales.

The offer: **€4,99 for the first 14 days, then €49 a year automatically** unless
the buyer cancels by day 14 (a Stripe subscription: the recurring €49 price, a
one-off €4,99 price, and a 14-day trial on the subscription). Lifetime stays a
manual purchase. The app is one DMG for everybody; a buyer passes the same three
ungated days, then enters the address they paid with, and the activation service
returns the paid key instead of a trial.

## What was built, and where

| Piece | Where | State |
| --- | --- | --- |
| Subscription keys: 30 days, refreshed in their last 7, 7 days of grace | `Service/src/subscription.js`, `activate.js`, `store.js` | committed, tests pass, **not deployed** |
| Intro purchase paid for 14 days; renewals use the invoice's period end | `Service/src/providers.js`, `webhook.js` | committed, **not deployed** |
| A refund or dispute cancels the Stripe subscription | `Service/src/billing.js`, `webhook.js` | committed; needs `STRIPE_API_KEY` |
| `POST /v1/subscriptions/cancel` (the website's cancellation button) | `Service/src/cancel.js` | committed; needs `STRIPE_API_KEY` |
| A lapsed or refunded address is told so, not handed a trial | `activate.js` (`subscription_inactive`) | committed |
| Silent key refresh in the app | `LicenseRefreshPolicy`, `EntitlementService.refreshSubscriptionKeyIfDue` | committed, **0.6.21 not released** |
| Neutral copy before a key arrives | `LicensePresentation`, `EntitlementNotice`, `StatusPresentation` | committed |
| Manage subscription (Settings, paywall) | `StoreFront.manageSubscription` → `witnessmac.com/manage` | committed |
| Sparkle checks once a day, with a Settings switch | `Info.plist`, `AppUpdater`, `SettingsView` | committed |
| `/start`, `/en/start`, `/start/danke`, `/kuendigen`, `/manage`, `/buy?plan=intro`, terms, privacy | website branch `feat/paid-entry-start` | **PR open, not merged** |
| Switch the ads | `~/Pet Project/witness-ads/paid_entry_switch.py` | dry run passes; `--apply` is Igor's |

## Still switched off, on purpose

- **No Payment Link for the intro offer.** `/start` shows "Der Kauf ist in Kürze
  möglich" and no buy button, and `/buy?plan=intro` sends the reader back to
  `/start`. Nothing can be bought until `introPaymentLink` in
  `website/app/_data/partnerOffers.ts` is set.
- **`customerPortalLink` is `null`.** `/manage` then falls back to the
  cancellation form.
- **`STRIPE_API_KEY` is not set.** Refunds still kill the licence; they do not
  cancel the subscription, and the cancellation form does nothing.

## What is done in Stripe (20.10.2026)

- Product `Witness` (`prod_VCHS4BFkION5VE`) has a new one-off price **€4,99,
  `price_1USjZyHOSgmME2jEEvvpRVN5`**, description "Einführung 14 Tage", lookup
  key `witness_intro_14_days`. It is in `Service/wrangler.toml` as `PRICE_INTRO`.
- The annual price is the existing `price_1UBsuZHOSgmME2jEqlNKU0Sn`.
- Creating the Payment Link was **refused by the permission classifier** at the
  "Include a free trial" box, so the link does not exist. The form was left
  unsaved in the dashboard tab.

## Order to switch it on

1. **Stripe, Payment Link** (Payments → Payment links → New): Witness, the
   €49/year price and the €4,99 price, quantity 1 each. Tick **Include a free
   trial**, 14 days. Keep *Enable Managed Payments* **off** and *Collect tax
   automatically* as on the two links from 4 October. **Do not allow promotion
   codes.** After payment: redirect to `https://witnessmac.com/start/danke`.
   Custom text under the button, one sentence: *€4,99 heute für die ersten 14
   Tage. Danach €49 pro Jahr, automatisch, wenn du nicht bis zum 14. Tag
   kündigst.* Copy the link's `plink_…` id and its `buy.stripe.com` URL.
2. **Stripe, reminders:** Settings → Billing → Subscriptions and emails → send a
   reminder before a trial ends and before renewal, and keep Smart Retries on.
3. **Stripe, customer portal:** Settings → Billing → Customer portal → *Activate
   link*. The portal's *default* configuration is shared with the Steliara
   products on this account; check it before relying on it, and use a separate
   configuration if Steliara's rules (plan switching, quantity) should not apply.
   Copy the login URL.
4. **Stripe, webhook:** the existing endpoint must send `checkout.session.completed`,
   `invoice.paid`, `invoice_payment.paid`, `charge.refunded` and
   `charge.dispute.created`. Renewals and refunds depend on all five.
5. **Stripe, restricted key** with *Subscriptions: write* and nothing else, then
   `cd Service && tools/set-secret.sh STRIPE_API_KEY`.
6. **Service:** put the link id into `Service/wrangler.toml` as
   `PAYMENT_LINK_INTRO = "plink_…"`, `cd Service && npm test`, `npx wrangler
   deploy`, and check `/v1/health`.
7. **App:** release 0.6.21 (`docs/PHASE_6_RELEASE.md`). It must be the latest
   release before the first sale: an older build does not refresh its key and a
   buyer on it is locked out after about a month.
8. **Website:** set `introPaymentLink` and `customerPortalLink` in
   `partnerOffers.ts`, merge the PR, deploy.
9. **Test in production with a real card:** buy the €4,99, install on a clean
   Mac, wait out the three days (or move the Mac's clock), enter the address, see
   "Annual subscription". Then refund it in Stripe and check that the licence is
   dead **and the subscription is cancelled** (Stripe → Subscriptions). Then
   cancel one through `/kuendigen` and check the mail.
10. **Ads:** `cd ~/Pet\ Project/witness-ads && .venv/bin/python
    paid_entry_switch.py` (dry run), then `--apply`. It switches the three ads'
    final URLs, replaces the headlines and descriptions that promise a free
    trial or a single price, and pauses the sitelinks, price assets and callouts
    that say the same or lead to the free page. `--revert --apply` undoes it.
11. **Three weeks without other ad changes.** Read: sessions on `/start`, clicks
    on `data-cta="start-buy"`, `license_purchased` with `kind = annual`, refunds,
    cancellations, and on day 15 the first €49 invoices. About 6 ad clicks a day
    means about 125 clicks.

## Revert

The ads: `paid_entry_switch.py --revert --apply`. The pages: remove
`introPaymentLink`. The service and the app are compatible with both.

## Open legal questions

For a lawyer, none created by this test alone: the wording of the pay button at
Stripe's checkout (§312j BGB), the cancellation form (§312k), automatic
extension after the intro (§309 Nr. 9) which also touches the existing annual
licence, and withdrawal for the intro period.
