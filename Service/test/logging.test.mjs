// What the log lines are allowed to contain.
//
// `docs/PHASE_8.md`: "a log line per issuance that carries the key id and never
// the address." A log that carries a customer's email is a log that has to be
// retained, deleted on request, and disclosed like the licence table itself —
// so the rule is worth more than a habit of remembering it at each call site.
//
// This drives a whole flow — a trial, a purchase, a renewal, a refund, a
// release, and every refusal — and asserts that nothing an address could be
// hiding in ever reaches a log call. It replaces watching `wrangler tail`
// during one live purchase, which proves that one purchase and nothing else.

import test from "node:test";
import assert from "node:assert/strict";

import { activate } from "../src/activate.js";
import { release } from "../src/release.js";
import { handleEvent } from "../src/webhook.js";
import { stripe } from "../src/providers.js";
import { Store } from "../src/store.js";
import { importSigningKey, importVerifyingKey } from "../src/signing.js";
import { makeTestDatabase } from "./support/d1.mjs";
import { makeKeypair } from "./support/keys.mjs";

const NOW = 1767225600;
const MAC = "0123456789abcdef0123456789abcdef";
const MAC_B = "fedcba9876543210fedcba9876543210";
const EMAIL = "a.very.identifiable.person@example.com";
const LOCAL_PART = "a.very.identifiable.person";
const DOMAIN = "example.com";

const env = { PAYMENT_LINK_LIFETIME: "plink_lifetime", PAYMENT_LINK_ANNUAL: "plink_annual" };

test("no log line anywhere in the flow can carry the customer's address", async () => {
  const { privateBase64, publicBase64 } = makeKeypair();
  const store = new Store(makeTestDatabase());
  const signingKey = await importSigningKey(privateBase64);
  const verifyingKey = await importVerifyingKey(publicBase64);
  const mailer = { async send() { return true; } };

  const lines = [];
  let counter = 0;
  const log = (message, fields = {}) => lines.push({ message, fields });
  const uuid = () => `00000000-0000-4000-8000-${String(counter++).padStart(12, "0")}`;

  const runActivate = (body, now = NOW) =>
    activate({ body, store, now, clientIP: "203.0.113.7", signingKey, mailer, log, uuid });

  // A trial, and the same press again.
  const issued = await runActivate({ device: MAC, email: EMAIL });
  await runActivate({ device: MAC, email: EMAIL });

  // Every refusal the endpoint can produce, each with the address in the body.
  await runActivate({ device: "not-a-device", email: EMAIL });
  await runActivate({ device: MAC, email: "not-an-address" });
  await runActivate({ device: MAC_B, email: EMAIL, now: NOW + 20 * 86400 });

  // A release, and one refused because the key names another Mac.
  await release({ body: { device: MAC, key: issued.body.key }, store, now: NOW, clientIP: "203.0.113.7", verifyingKey, log });
  await release({ body: { device: MAC_B, key: issued.body.key }, store, now: NOW, clientIP: "203.0.113.7", verifyingKey, log });

  const deliver = (event, now = NOW) =>
    handleEvent({ event, provider: stripe, env, store, now, mailer, log, uuid });

  // A purchase, a sale that is not ours, a renewal, and a refund.
  await deliver({
    id: "evt_buy",
    type: "checkout.session.completed",
    data: {
      object: {
        id: "cs_1",
        subscription: "sub_1",
        payment_link: "plink_annual",
        customer_details: { email: EMAIL },
      },
    },
  });
  await deliver({
    id: "evt_other",
    type: "checkout.session.completed",
    data: { object: { id: "cs_2", payment_link: "plink_elsewhere", customer_details: { email: EMAIL } } },
  });
  await deliver(
    {
      id: "evt_renew",
      type: "invoice.paid",
      data: { object: { id: "in_1", subscription: "sub_1", charge: "ch_1", billing_reason: "subscription_cycle", customer_email: EMAIL } },
    },
    NOW + 360 * 86400,
  );
  await deliver(
    { id: "evt_refund", type: "charge.refunded", data: { object: { id: "ch_1", payment_intent: "pi_1", billing_details: { email: EMAIL } } } },
    NOW + 361 * 86400,
  );

  assert.ok(lines.length >= 8, `expected the flow to log something; got ${lines.length} lines`);

  const text = JSON.stringify(lines);
  assert.ok(!text.includes(EMAIL), "a log line carries the whole address");
  assert.ok(!text.includes(LOCAL_PART), "a log line carries the address's local part");
  assert.ok(!text.includes(DOMAIN), "a log line carries the address's domain");
  assert.ok(!text.includes("@"), `a log line carries an "@": ${text}`);

  // The device hash is not personal data — it cannot be turned back into a
  // serial number — but it is the one identifier that follows a Mac around, and
  // there is no reason for it to be in a log either. The key id is what a
  // support conversation is conducted in.
  assert.ok(!text.includes(MAC), "a log line carries the device hash");
  assert.ok(!text.includes(MAC_B), "a log line carries the device hash");

  // And an IP address, which is a rate-limit counter and nothing else.
  assert.ok(!text.includes("203.0.113.7"), "a log line carries the caller's IP");
});

test("what the log lines do carry is enough to support a customer", async () => {
  const { privateBase64 } = makeKeypair();
  const store = new Store(makeTestDatabase());
  const signingKey = await importSigningKey(privateBase64);
  const lines = [];
  let counter = 0;

  await activate({
    body: { device: MAC, email: EMAIL },
    store,
    now: NOW,
    clientIP: "203.0.113.7",
    signingKey,
    mailer: { async send() { return true; } },
    log: (message, fields = {}) => lines.push({ message, fields }),
    uuid: () => `00000000-0000-4000-8000-${String(counter++).padStart(12, "0")}`,
  });

  const issuance = lines.find((line) => line.message === "key issued");
  assert.ok(issuance, "an issuance is logged");
  assert.match(issuance.fields.key_id, /^[0-9a-f-]{36}$/);
  assert.equal(issuance.fields.kind, "trial");
  assert.equal(issuance.fields.slot, "new");
});
