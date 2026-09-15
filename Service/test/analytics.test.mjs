// What reaches PostHog, asserted on the bytes that would leave.
//
// The module is used for real and only the network is replaced, so every
// assertion here is about the request body PostHog would receive — which is
// the thing `docs/PRIVACY.md` describes, and the thing that must never carry
// an address.

import test from "node:test";
import assert from "node:assert/strict";

import { createAnalytics, money, ALLOWED_PROPERTIES } from "../src/analytics.js";
import { activate } from "../src/activate.js";
import { handleEvent } from "../src/webhook.js";
import { stripe } from "../src/providers.js";
import { Store } from "../src/store.js";
import { importSigningKey } from "../src/signing.js";
import { makeTestDatabase } from "./support/d1.mjs";
import { makeKeypair } from "./support/keys.mjs";

const NOW = 1767225600;
const MAC = "0123456789abcdef0123456789abcdef";
const EMAIL = "buyer@example.com";
const KEY = "phc_test";

const env = {
  POSTHOG_KEY: KEY,
  PAYMENT_LINK_LIFETIME: "plink_lifetime",
  PAYMENT_LINK_ANNUAL: "plink_annual",
};

function recorder(overrides = {}) {
  const sent = [];
  const analytics = createAnalytics(
    { ...env, ...overrides },
    {
      fetcher: async (url, init) => {
        sent.push({ url, body: JSON.parse(init.body) });
        return { ok: true, status: 200 };
      },
    },
  );
  return { analytics, sent, names: () => sent.map((s) => s.body.event) };
}

async function harness(overrides = {}) {
  const { privateBase64 } = makeKeypair();
  const store = new Store(makeTestDatabase());
  const signingKey = await importSigningKey(privateBase64);
  const rec = recorder(overrides);
  let counter = 0;
  const uuid = () => `00000000-0000-4000-8000-${String(counter++).padStart(12, "0")}`;

  return {
    ...rec,
    store,
    activate: ({ email = EMAIL, device = MAC, now = NOW } = {}) =>
      activate({
        body: { device, email },
        store,
        now,
        clientIP: "203.0.113.7",
        signingKey,
        mailer: { async send() { return true; } },
        analytics: rec.analytics,
        log: () => {},
        uuid,
      }),
    deliver: (event, { now = NOW } = {}) =>
      handleEvent({
        event,
        provider: stripe,
        env,
        store,
        now,
        mailer: { async send() { return true; } },
        analytics: rec.analytics,
        log: () => {},
        uuid,
      }),
  };
}

const checkout = (link, { id = "evt_buy", session = "cs_1", subscription, amount = 9900 } = {}) => ({
  id,
  type: "checkout.session.completed",
  data: {
    object: {
      id: session,
      payment_intent: subscription ? undefined : "pi_1",
      subscription,
      payment_link: link,
      amount_total: amount,
      currency: "eur",
      customer_details: { email: EMAIL },
    },
  },
});

// MARK: - The boundary

test("with no key configured nothing is sent", async () => {
  let calls = 0;
  const analytics = createAnalytics({}, { fetcher: async () => { calls += 1; return { ok: true }; } });

  assert.equal(analytics.enabled, false);
  analytics.capture("trial_issued", "lic_1", { kind: "trial" });
  assert.equal(calls, 0);
});

test("a host outside PostHog's EU region is refused rather than used", async () => {
  const { analytics, sent } = recorder({ POSTHOG_HOST: "https://us.i.posthog.com" });

  assert.equal(analytics.enabled, false);
  analytics.capture("trial_issued", "lic_1", { kind: "trial" });
  assert.equal(sent.length, 0);
});

test("an event carries the licence id, the allowlisted properties, and no address", async () => {
  const { analytics, sent } = recorder();

  await analytics.capture(
    "license_purchased",
    "lic_1",
    // Everything a careless caller might hand over from a licence row.
    { kind: "lifetime", revenue: 99, currency: "EUR", email: EMAIL, device: MAC, ip: "203.0.113.7" },
    NOW,
  );

  assert.equal(sent.length, 1);
  assert.equal(sent[0].url, "https://eu.i.posthog.com/i/v0/e/");
  const { body } = sent[0];
  assert.equal(body.api_key, KEY);
  assert.equal(body.event, "license_purchased");
  assert.equal(body.distinct_id, "lic_1");
  assert.equal(body.timestamp, new Date(NOW * 1000).toISOString());

  assert.deepEqual(
    Object.keys(body.properties).sort(),
    ["$geoip_disable", "$process_person_profile", "currency", "kind", "revenue", "source"],
  );
  assert.equal(body.properties.$process_person_profile, false);
  assert.equal(body.properties.$geoip_disable, true);
  assert.equal(JSON.stringify(body).includes("@"), false, "an address reached PostHog");
  assert.equal(JSON.stringify(body).includes(MAC), false, "a device identifier reached PostHog");
});

test("only the four named events can be sent", async () => {
  const { analytics, sent } = recorder();
  await analytics.capture("identify", "lic_1", {});
  await analytics.capture("$pageview", "lic_1", {});
  assert.equal(sent.length, 0);
  assert.deepEqual(ALLOWED_PROPERTIES.sort(), ["currency", "kind", "provider", "revenue", "upgrade"]);
});

test("a failure to reach PostHog is swallowed, never thrown into a purchase", async () => {
  const analytics = createAnalytics(env, { fetcher: async () => { throw new TypeError("offline"); } });
  await assert.doesNotReject(analytics.capture("trial_issued", "lic_1", { kind: "trial" }));
});

test("Stripe's minor units become major units, zero-decimal currencies left alone", () => {
  assert.deepEqual(money(9900, "eur"), { revenue: 99, currency: "EUR" });
  assert.deepEqual(money(4900, "usd"), { revenue: 49, currency: "USD" });
  assert.deepEqual(money(1500, "jpy"), { revenue: 1500, currency: "JPY" });
  assert.deepEqual(money(null, "eur"), {});
  assert.deepEqual(money(9900, undefined), {});
});

// MARK: - Where the events come from

test("a trial is counted when it is created, and not again when the key is fetched twice", async () => {
  const h = await harness();

  assert.equal((await h.activate()).status, 200);
  assert.equal((await h.activate()).status, 200);

  assert.deepEqual(h.names(), ["trial_issued"]);
  assert.deepEqual(Object.keys(h.sent[0].body.properties).sort(), ["$geoip_disable", "$process_person_profile", "kind", "source"]);
  assert.equal(h.sent[0].body.properties.kind, "trial");
});

test("a refused second trial is not counted", async () => {
  const h = await harness();
  await h.activate();
  const second = await h.activate({ email: "other@example.com" });

  assert.equal(second.status, 422);
  assert.deepEqual(h.names(), ["trial_issued"]);
});

test("a purchase is counted with what was paid, and a redelivery is not counted twice", async () => {
  const h = await harness();

  await h.deliver(checkout("plink_lifetime"));
  await h.deliver(checkout("plink_lifetime"));

  assert.deepEqual(h.names(), ["license_purchased"]);
  const { properties } = h.sent[0].body;
  assert.equal(properties.kind, "lifetime");
  assert.equal(properties.revenue, 99);
  assert.equal(properties.currency, "EUR");
  assert.equal(properties.provider, "stripe");
  assert.equal(properties.upgrade, false);
});

test("fetching the key a purchase paid for is not a trial", async () => {
  const h = await harness();
  await h.deliver(checkout("plink_lifetime"));
  await h.activate();

  assert.deepEqual(h.names(), ["license_purchased"]);
});

test("a lifetime bought over an annual is a lifetime sale marked as an upgrade", async () => {
  const h = await harness();
  await h.deliver(checkout("plink_annual", { id: "evt_a", session: "cs_a", subscription: "sub_1", amount: 4900 }));
  await h.deliver(checkout("plink_lifetime", { id: "evt_b", session: "cs_b", amount: 9900 }));

  assert.deepEqual(h.names(), ["license_purchased", "license_purchased"]);
  assert.equal(h.sent[1].body.properties.kind, "lifetime");
  assert.equal(h.sent[1].body.properties.upgrade, true);
});

test("a renewal and a refund are counted, the refund as negative revenue", async () => {
  const h = await harness();
  await h.deliver(checkout("plink_annual", { subscription: "sub_1", amount: 4900 }));

  await h.deliver(
    {
      id: "evt_renew",
      type: "invoice.paid",
      data: { object: { id: "in_2", subscription: "sub_1", billing_reason: "subscription_cycle", amount_paid: 4900, currency: "eur", charge: "ch_2" } },
    },
    { now: NOW + 365 * 86400 },
  );
  await h.deliver(
    { id: "evt_refund", type: "charge.refunded", data: { object: { id: "ch_2", amount_refunded: 4900, currency: "eur" } } },
    { now: NOW + 366 * 86400 },
  );

  assert.deepEqual(h.names(), ["license_purchased", "license_renewed", "license_refunded"]);
  assert.equal(h.sent[1].body.properties.revenue, 49);
  assert.equal(h.sent[2].body.properties.revenue, -49);
});

test("another product's sale on the same Stripe account is not counted", async () => {
  const h = await harness();
  await h.deliver(checkout("plink_someone_elses_product"));
  await h.deliver({ id: "evt_r", type: "charge.refunded", data: { object: { id: "ch_other", amount_refunded: 1000, currency: "eur" } } });

  assert.deepEqual(h.names(), []);
});
