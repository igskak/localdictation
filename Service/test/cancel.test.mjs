// The website's cancellation button: it ends renewal, honours the paid time,
// confirms by mail, and never says whether an address was a customer.

import test from "node:test";
import assert from "node:assert/strict";

import { cancelSubscription, CANCEL_LIMITS } from "../src/cancel.js";
import { Store } from "../src/store.js";
import { makeTestDatabase } from "./support/d1.mjs";

const NOW = 1767225600;
const EMAIL = "buyer@example.com";

async function harness() {
  const store = new Store(makeTestDatabase());
  const sent = [];
  const stopped = [];
  const events = [];
  const billing = {
    async cancelAtPeriodEnd(id) {
      stopped.push(id);
      return true;
    },
  };
  return {
    store,
    sent,
    stopped,
    events,
    call(body, { now = NOW, ip = "203.0.113.9" } = {}) {
      return cancelSubscription({
        body,
        store,
        now,
        clientIP: ip,
        billing,
        mailer: { async send(message) { sent.push(message); return true; } },
        analytics: { capture(event, id, properties) { events.push({ event, id, properties }); } },
        log: () => {},
      });
    },
  };
}

async function subscribe(store, { email = EMAIL, sub = "sub_1" } = {}) {
  await store.createLicense({ id: `lic-${sub}`, email, kind: "annual", issuedAt: NOW, expiresAt: NOW + 100 * 86400 });
  await store.recordRefs(`lic-${sub}`, [sub, "cs_1"], NOW);
}

test("cancelling stops the subscription at the end of the period and mails the confirmation", async () => {
  const h = await harness();
  await subscribe(h.store);

  const result = await h.call({ email: " Buyer@Example.com " });
  assert.equal(result.status, 200);
  assert.deepEqual(h.stopped, ["sub_1"]);
  assert.equal(h.sent.length, 1);
  assert.match(h.sent[0].text, /does not renew/);
});

test("an address with no subscription gets the same answer and no mail", async () => {
  const h = await harness();
  const result = await h.call({ email: "stranger@example.com" });
  const real = await (async () => {
    await subscribe(h.store);
    return h.call({ email: EMAIL });
  })();

  assert.equal(result.status, 200);
  assert.deepEqual(result.body, real.body);
  assert.deepEqual(h.stopped, ["sub_1"]);
  assert.equal(h.sent.length, 1);
});

test("an address that is not one is refused", async () => {
  const h = await harness();
  assert.equal((await h.call({ email: "nope" })).status, 400);
});

test("the same address cannot be asked about without limit", async () => {
  const h = await harness();
  await subscribe(h.store);
  for (let i = 0; i < CANCEL_LIMITS.email.limit; i += 1) await h.call({ email: EMAIL });
  assert.equal((await h.call({ email: EMAIL })).status, 429);
});

test("a cancellation is counted without saying who asked", async () => {
  const h = await harness();
  await subscribe(h.store);
  await h.call({ email: EMAIL });
  await h.call({ email: "stranger@example.com" });

  assert.equal(h.events.length, 1);
  assert.equal(h.events[0].event, "subscription_cancel_requested");
  assert.equal(h.events[0].id, "lic-sub_1");
  assert.deepEqual(h.events[0].properties, { kind: "annual" });
});
