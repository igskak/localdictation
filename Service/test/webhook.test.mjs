// Money becoming an entitlement, and the two ways that goes wrong.
//
// The signature is one of them and redelivery is the other. Both providers are
// tested because `docs/PHASE_8_DECISIONS.md` D2 is settled on availability, and
// the point of writing both was that the decision could be made late.

import test from "node:test";
import assert from "node:assert/strict";

import { handleEvent } from "../src/webhook.js";
import { paddle, stripe, ANNUAL_SECONDS, MAXIMUM_SIGNATURE_AGE } from "../src/providers.js";
import { activate } from "../src/activate.js";
import { Store } from "../src/store.js";
import { importSigningKey, importVerifyingKey } from "../src/signing.js";
import { verifyToken } from "../src/token.js";
import { makeTestDatabase } from "./support/d1.mjs";
import { makeKeypair } from "./support/keys.mjs";

const NOW = 1767225600;
const MAC = "0123456789abcdef0123456789abcdef";
const EMAIL = "buyer@example.com";
const SECRET = "whsec_test";

const env = {
  PRICE_LIFETIME: "pri_lifetime",
  PRICE_ANNUAL: "pri_annual",
  PAYMENT_LINK_LIFETIME: "plink_lifetime",
  PAYMENT_LINK_ANNUAL: "plink_annual",
};

async function harness() {
  const { privateBase64, publicBase64 } = makeKeypair();
  const store = new Store(makeTestDatabase());
  const sent = [];
  let counter = 0;
  const signingKey = await importSigningKey(privateBase64);

  return {
    store,
    sent,
    async verifying() {
      return importVerifyingKey(publicBase64);
    },
    async deliver(event, { provider = paddle, now = NOW } = {}) {
      return handleEvent({
        event,
        provider,
        env,
        store,
        now,
        mailer: {
          async send(message) {
            sent.push(message);
            return true;
          },
        },
        log: () => {},
        uuid: () => `00000000-0000-4000-8000-${String(counter++).padStart(12, "0")}`,
      });
    },
    async activate({ email = EMAIL, device = MAC, now = NOW } = {}) {
      return activate({
        body: { device, email },
        store,
        now,
        clientIP: "203.0.113.7",
        signingKey,
        mailer: { async send() { return true; } },
        log: () => {},
        uuid: () => `00000000-0000-4000-8000-${String(counter++).padStart(12, "0")}`,
      });
    },
  };
}

const paddlePurchase = (kind, { id = "evt_1", orderID = "txn_1", email = EMAIL } = {}) => ({
  event_id: id,
  event_type: "transaction.completed",
  data: {
    id: orderID,
    customer: { email },
    items: [{ price: { id: kind === "lifetime" ? "pri_lifetime" : "pri_annual" } }],
  },
});

const stripePurchase = (kind, { id = "evt_1", orderID = "cs_1", email = EMAIL } = {}) => ({
  id,
  type: "checkout.session.completed",
  data: {
    object: {
      id: orderID,
      customer_details: { email },
      metadata: { price_id: kind === "lifetime" ? "pri_lifetime" : "pri_annual" },
    },
  },
});

// MARK: - Signatures

test("a Paddle signature is checked over the body as it arrived", async () => {
  const body = JSON.stringify(paddlePurchase("lifetime"));
  const signature = await hmac(`${NOW}:${body}`);

  assert.equal(await paddle.verify({ header: `ts=${NOW};h1=${signature}`, body, secret: SECRET, now: NOW }), true);
  assert.equal(await paddle.verify({ header: `ts=${NOW};h1=${signature}`, body: `${body} `, secret: SECRET, now: NOW }), false);
  assert.equal(await paddle.verify({ header: `ts=${NOW};h1=${"0".repeat(64)}`, body, secret: SECRET, now: NOW }), false);
  assert.equal(await paddle.verify({ header: null, body, secret: SECRET, now: NOW }), false);
});

test("a Stripe signature is checked, and several v1 values are allowed during a rotation", async () => {
  const body = JSON.stringify(stripePurchase("annual"));
  const signature = await hmac(`${NOW}.${body}`);

  assert.equal(await stripe.verify({ header: `t=${NOW},v1=${signature}`, body, secret: SECRET, now: NOW }), true);
  assert.equal(
    await stripe.verify({ header: `t=${NOW},v1=${"0".repeat(64)},v1=${signature}`, body, secret: SECRET, now: NOW }),
    true,
  );
  assert.equal(await stripe.verify({ header: `t=${NOW},v1=${"0".repeat(64)}`, body, secret: SECRET, now: NOW }), false);
});

test("a replayed delivery from last week is not a delivery attempt", async () => {
  const body = JSON.stringify(paddlePurchase("lifetime"));
  const old = NOW - MAXIMUM_SIGNATURE_AGE - 1;
  const signature = await hmac(`${old}:${body}`);
  assert.equal(await paddle.verify({ header: `ts=${old};h1=${signature}`, body, secret: SECRET, now: NOW }), false);
});

// MARK: - What a purchase does

test("a lifetime purchase becomes a license on the address, and one instruction", async () => {
  const h = await harness();
  const result = await h.deliver(paddlePurchase("lifetime"));

  assert.equal(result.status, 200);
  assert.equal(result.body.applied, true);

  const license = await h.store.strongestLicense(EMAIL, NOW);
  assert.equal(license.kind, "lifetime");
  assert.equal(license.expires_at, null);
  assert.equal(license.provider_order_id, "txn_1");

  assert.equal(h.sent.length, 1);
  assert.match(h.sent[0].text, /Send my key/);
  assert.ok(!h.sent[0].text.includes("LD1."), "the purchase mail cannot carry a key: nobody knows the Mac yet");
});

test("buying, then Send my key on that address, unlocks the Mac", async () => {
  const h = await harness();
  await h.deliver(paddlePurchase("lifetime"));

  const activated = await h.activate();
  assert.equal(activated.status, 200);
  assert.equal((await verifyToken(activated.body.key, await h.verifying())).kind, "lifetime");
});

test("buying on an expired trial replaces the wall with a license", async () => {
  const h = await harness();
  await h.activate();                                     // trial
  await h.deliver(paddlePurchase("annual"), { now: NOW + 20 * 86400 });

  const activated = await h.activate({ now: NOW + 20 * 86400 });
  const payload = await verifyToken(activated.body.key, await h.verifying());
  assert.equal(payload.kind, "annual");
  assert.equal(payload.device, MAC);
});

test("an annual renewal extends from the current expiry rather than from today", async () => {
  const h = await harness();
  await h.deliver(paddlePurchase("annual", { id: "evt_1", orderID: "txn_1" }));
  const first = await h.store.strongestLicense(EMAIL, NOW);

  await h.deliver(paddlePurchase("annual", { id: "evt_2", orderID: "txn_2" }), { now: NOW + 30 * 86400 });
  const second = await h.store.strongestLicense(EMAIL, NOW + 30 * 86400);

  assert.equal(second.id, first.id);
  assert.equal(second.expires_at, first.expires_at + ANNUAL_SECONDS);
});

test("a lifetime bought on top of an annual loses the date", async () => {
  const h = await harness();
  await h.deliver(paddlePurchase("annual", { id: "evt_1", orderID: "txn_1" }));
  await h.deliver(paddlePurchase("lifetime", { id: "evt_2", orderID: "txn_2" }), { now: NOW + 86400 });

  const license = await h.store.strongestLicense(EMAIL, NOW + 86400);
  assert.equal(license.kind, "lifetime");
  assert.equal(license.expires_at, null);
});

test("Stripe events do the same thing", async () => {
  const h = await harness();
  await h.deliver(stripePurchase("lifetime"), { provider: stripe });

  const license = await h.store.strongestLicense(EMAIL, NOW);
  assert.equal(license.kind, "lifetime");
  assert.equal(license.provider_order_id, "cs_1");
});

// MARK: - Redelivery, refunds, and events this service does not know

test("every provider re-delivers, and the second delivery changes nothing", async () => {
  const h = await harness();
  await h.deliver(paddlePurchase("lifetime"));
  const again = await h.deliver(paddlePurchase("lifetime"));

  assert.equal(again.body.applied, false);
  assert.equal((await h.store.all("SELECT id FROM licenses")).length, 1);
  assert.equal(h.sent.length, 1);
});

test("a refund stops further issuance and leaves the key already out alone", async () => {
  const h = await harness();
  await h.deliver(paddlePurchase("lifetime"));
  const issued = await h.activate();

  await h.deliver(
    { event_id: "evt_refund", event_type: "adjustment.created", data: { action: "refund", transaction_id: "txn_1" } },
    { now: NOW + 86400 },
  );

  const license = await h.store.licenseByOrder("txn_1");
  assert.equal(license.status, "dead");
  assert.equal(await h.store.strongestLicense(EMAIL, NOW + 86400), null);

  // Phase 6's bill, paid knowingly.
  assert.notEqual(await verifyToken(issued.body.key, await h.verifying()), null);
});

test("an event this service has no mapping for is answered once and not retried forever", async () => {
  const h = await harness();
  const result = await h.deliver({
    event_id: "evt_x",
    event_type: "transaction.completed",
    data: { id: "txn_x", items: [{ price: { id: "pri_something_else" } }] },
  });

  assert.equal(result.status, 202);
  assert.equal(result.body.applied, false);
  assert.equal((await h.store.all("SELECT id FROM licenses")).length, 0);
});

test("an event of a kind this service does not act on is acknowledged", async () => {
  const h = await harness();
  const result = await h.deliver({ event_id: "evt_y", event_type: "customer.updated", data: { id: "ctm_1" } });
  assert.equal(result.status, 200);
  assert.equal(result.body.applied, false);
});

// MARK: - Stripe, specifically
//
// D2 is executed: Stripe Managed Payments. Everything below is a payload shape
// that only Stripe produces, and the two that matter are the ones a Paddle-
// shaped reading would have got wrong.

test("a Payment Link purchase is identified by the link, because Stripe sends no line items", async () => {
  const h = await harness();
  // Exactly what a Payment Link checkout carries: no line_items, no metadata,
  // and the link's own id.
  await h.deliver(
    {
      id: "evt_link",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_1",
          payment_intent: "pi_1",
          payment_link: "plink_lifetime",
          customer_details: { email: EMAIL },
        },
      },
    },
    { provider: stripe },
  );

  const license = await h.store.strongestLicense(EMAIL, NOW);
  assert.equal(license.kind, "lifetime");
  assert.equal(license.provider_order_id, "pi_1", "the payment intent is what a refund names");
});

test("a subscription renewal a year later extends the licence", async () => {
  const h = await harness();
  await h.deliver(
    {
      id: "evt_first",
      type: "checkout.session.completed",
      data: {
        object: { id: "cs_1", subscription: "sub_1", payment_link: "plink_annual", customer_details: { email: EMAIL } },
      },
    },
    { provider: stripe },
  );
  const first = await h.store.strongestLicense(EMAIL, NOW);
  assert.equal(first.kind, "annual");

  const renewalAt = NOW + 360 * 86400;
  const renewal = await h.deliver(
    {
      id: "evt_renewal",
      type: "invoice.paid",
      data: {
        object: {
          id: "in_1",
          subscription: "sub_1",
          billing_reason: "subscription_cycle",
          customer_email: EMAIL,
          lines: { data: [{ price: { id: "pri_annual" } }] },
        },
      },
    },
    { provider: stripe, now: renewalAt },
  );

  assert.equal(renewal.body.applied, true);
  const second = await h.store.strongestLicense(EMAIL, renewalAt);
  assert.equal(second.id, first.id, "a renewal is the same licence, not a second one");
  assert.equal(second.expires_at, first.expires_at + ANNUAL_SECONDS);
  assert.equal(await h.store.liveSlotCount(first.id), 0);

  // The key on the Mac still carries the old date, so the renewal has to say
  // how to replace it. This is the mail that keeps a paying subscriber from
  // being locked out on their renewal day.
  assert.match(h.sent.at(-1).text, /Send my key/);
  assert.match(h.sent.at(-1).subject, /renewed/i);
});

test("a renewed licence hands the same Mac a key with the new date", async () => {
  const h = await harness();
  await h.deliver(
    {
      id: "evt_first",
      type: "checkout.session.completed",
      data: { object: { id: "cs_1", subscription: "sub_1", payment_link: "plink_annual", customer_details: { email: EMAIL } } },
    },
    { provider: stripe },
  );
  const before = await h.activate();

  const renewalAt = NOW + 360 * 86400;
  await h.deliver(
    {
      id: "evt_renewal",
      type: "invoice.paid",
      data: {
        object: {
          id: "in_1",
          subscription: "sub_1",
          billing_reason: "subscription_cycle",
          customer_email: EMAIL,
          lines: { data: [{ price: { id: "pri_annual" } }] },
        },
      },
    },
    { provider: stripe, now: renewalAt },
  );

  const after = await h.activate({ now: renewalAt + 60 });
  assert.notEqual(after.body.key, before.body.key);
  const payload = await verifyToken(after.body.key, await h.verifying());
  assert.equal(payload.expires, NOW + 2 * ANNUAL_SECONDS);
});

test("the first invoice of a subscription is left to the checkout session", async () => {
  const h = await harness();
  const result = await h.deliver(
    {
      id: "evt_first_invoice",
      type: "invoice.paid",
      data: {
        object: {
          id: "in_0",
          billing_reason: "subscription_create",
          customer_email: EMAIL,
          lines: { data: [{ price: { id: "pri_annual" } }] },
        },
      },
    },
    { provider: stripe },
  );

  assert.equal(result.body.applied, false);
  assert.equal((await h.store.all("SELECT id FROM licenses")).length, 0, "or the address gets two licences for one sale");
});

/// Both invoice events fire for the same money and carry different event ids,
/// so idempotency cannot save us: acting on both would grow an annual by two
/// years for one payment. Selecting both in the dashboard has to be harmless.
test("invoice.payment_succeeded is ignored, so ticking both boxes cannot double the term", async () => {
  const h = await harness();
  await h.deliver(
    {
      id: "evt_first",
      type: "checkout.session.completed",
      data: { object: { id: "cs_1", subscription: "sub_1", payment_link: "plink_annual", customer_details: { email: EMAIL } } },
    },
    { provider: stripe },
  );
  const first = await h.store.strongestLicense(EMAIL, NOW);

  const renewalAt = NOW + 360 * 86400;
  const invoice = {
    id: "in_1",
    subscription: "sub_1",
    billing_reason: "subscription_cycle",
    customer_email: EMAIL,
    lines: { data: [{ price: { id: "pri_annual" } }] },
  };
  await h.deliver({ id: "evt_a", type: "invoice.paid", data: { object: invoice } }, { provider: stripe, now: renewalAt });
  await h.deliver(
    { id: "evt_b", type: "invoice.payment_succeeded", data: { object: invoice } },
    { provider: stripe, now: renewalAt },
  );

  const after = await h.store.strongestLicense(EMAIL, renewalAt);
  assert.equal(after.expires_at, first.expires_at + ANNUAL_SECONDS, "one payment, one year");
});

test("a refunded first subscription payment is found by the invoice recorded at checkout", async () => {
  const h = await harness();
  await h.deliver(
    {
      id: "evt_first",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_1",
          subscription: "sub_1",
          invoice: "in_1",
          payment_link: "plink_annual",
          customer_details: { email: EMAIL },
        },
      },
    },
    { provider: stripe },
  );

  const refunded = await h.deliver(
    {
      id: "evt_refund",
      type: "charge.refunded",
      // A subscription charge names an invoice and a payment intent this
      // service never saw. The invoice is the one it did.
      data: { object: { id: "ch_1", payment_intent: "pi_never_seen", invoice: "in_1" } },
    },
    { provider: stripe, now: NOW + 86400 },
  );

  assert.equal(refunded.body.applied, true);
  assert.equal(await h.store.strongestLicense(EMAIL, NOW + 86400), null);
});

test("a refund after a renewal is found by the charge that renewal recorded", async () => {
  const h = await harness();
  await h.deliver(
    {
      id: "evt_first",
      type: "checkout.session.completed",
      data: { object: { id: "cs_1", subscription: "sub_1", payment_link: "plink_annual", customer_details: { email: EMAIL } } },
    },
    { provider: stripe },
  );
  const renewalAt = NOW + 360 * 86400;
  await h.deliver(
    {
      id: "evt_renewal",
      type: "invoice.paid",
      data: {
        object: { id: "in_2", subscription: "sub_1", charge: "ch_2", billing_reason: "subscription_cycle" },
      },
    },
    { provider: stripe, now: renewalAt },
  );

  const refunded = await h.deliver(
    { id: "evt_refund", type: "charge.refunded", data: { object: { id: "ch_2", payment_intent: "pi_2" } } },
    { provider: stripe, now: renewalAt + 86400 },
  );

  assert.equal(refunded.body.applied, true);
  assert.equal(await h.store.strongestLicense(EMAIL, renewalAt + 86400), null);
});

// MARK: - One payment account, two products
//
// Stripe sends every event on an account to every webhook endpoint, and this
// account sells something else as well. So the question "is this event mine"
// has to be answered from something this service wrote down -- never from the
// customer's address, which two products can share down to the character.

test("a checkout for another product on the same account creates nothing", async () => {
  const h = await harness();
  const result = await h.deliver(
    {
      id: "evt_other",
      type: "checkout.session.completed",
      data: {
        object: {
          id: "cs_other",
          payment_intent: "pi_other",
          payment_link: "plink_the_other_product",
          customer_details: { email: EMAIL },
        },
      },
    },
    { provider: stripe },
  );

  assert.equal(result.status, 202);
  assert.equal((await h.store.all("SELECT id FROM licenses")).length, 0);
});

test("a refund for another product cannot kill this product's licence", async () => {
  const h = await harness();
  // The same person owns both. One address, two purchases, one payment account.
  await h.deliver(
    {
      id: "evt_ours",
      type: "checkout.session.completed",
      data: { object: { id: "cs_ours", payment_intent: "pi_ours", payment_link: "plink_lifetime", customer_details: { email: EMAIL } } },
    },
    { provider: stripe },
  );

  const refunded = await h.deliver(
    {
      id: "evt_refund_other",
      type: "charge.refunded",
      data: { object: { id: "ch_other", payment_intent: "pi_other", billing_details: { email: EMAIL } } },
    },
    { provider: stripe, now: NOW + 86400 },
  );

  assert.equal(refunded.body.applied, false);
  const license = await h.store.strongestLicense(EMAIL, NOW + 86400);
  assert.equal(license.kind, "lifetime", "still live: that refund was about something else");
  assert.equal(license.status, "live");
});

test("a renewal of another product's subscription extends nothing here", async () => {
  const h = await harness();
  await h.deliver(
    {
      id: "evt_ours",
      type: "checkout.session.completed",
      data: { object: { id: "cs_ours", subscription: "sub_ours", payment_link: "plink_annual", customer_details: { email: EMAIL } } },
    },
    { provider: stripe },
  );
  const before = await h.store.strongestLicense(EMAIL, NOW);

  const result = await h.deliver(
    {
      id: "evt_other_renewal",
      type: "invoice.paid",
      data: {
        object: { id: "in_other", subscription: "sub_the_other_product", billing_reason: "subscription_cycle", customer_email: EMAIL },
      },
    },
    { provider: stripe, now: NOW + 360 * 86400 },
  );

  assert.equal(result.body.applied, false);
  const after = await h.store.strongestLicense(EMAIL, NOW + 360 * 86400);
  assert.equal(after.expires_at, before.expires_at, "a year the buyer did not pay us for");
});

test("the subscription is read from either place Stripe puts it on an invoice", async () => {
  const h = await harness();
  await h.deliver(
    {
      id: "evt_first",
      type: "checkout.session.completed",
      data: { object: { id: "cs_1", subscription: "sub_1", payment_link: "plink_annual", customer_details: { email: EMAIL } } },
    },
    { provider: stripe },
  );
  const before = await h.store.strongestLicense(EMAIL, NOW);

  // The newer API shape. An account whose version rolls forward must not
  // silently stop renewing anybody.
  const renewalAt = NOW + 360 * 86400;
  const result = await h.deliver(
    {
      id: "evt_renewal",
      type: "invoice.paid",
      data: {
        object: {
          id: "in_2",
          billing_reason: "subscription_cycle",
          parent: { subscription_details: { subscription: "sub_1" } },
        },
      },
    },
    { provider: stripe, now: renewalAt },
  );

  assert.equal(result.body.applied, true);
  const after = await h.store.strongestLicense(EMAIL, renewalAt);
  assert.equal(after.expires_at, before.expires_at + ANNUAL_SECONDS);
});

test("a cancelled subscription runs to its date rather than dying on the spot", async () => {
  const h = await harness();
  await h.deliver(
    {
      id: "evt_first",
      type: "checkout.session.completed",
      data: { object: { id: "cs_1", subscription: "sub_1", payment_link: "plink_annual", customer_details: { email: EMAIL } } },
    },
    { provider: stripe },
  );

  const cancelled = await h.deliver(
    { id: "evt_cancel", type: "customer.subscription.deleted", data: { object: { id: "sub_1" } } },
    { provider: stripe, now: NOW + 86400 },
  );

  assert.equal(cancelled.body.applied, false);
  const license = await h.store.strongestLicense(EMAIL, NOW + 86400);
  assert.equal(license.kind, "annual", "they paid for the year and the year is not over");
});

async function hmac(message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
