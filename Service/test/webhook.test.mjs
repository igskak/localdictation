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

const env = { PRICE_LIFETIME: "pri_lifetime", PRICE_ANNUAL: "pri_annual" };

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
