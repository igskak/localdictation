// What every answer the endpoint can give does to a person.
//
// The status codes and bodies here are the ones `HTTPActivationBackendTests`
// pins from the other side. The two files are the same contract read from the
// two ends, which is the only arrangement in which "it works" means anything.

import test from "node:test";
import assert from "node:assert/strict";

import { activate, TRIAL_SECONDS, DEVICE_LIMIT, RATE_LIMITS } from "../src/activate.js";
import { Store } from "../src/store.js";
import { importSigningKey, importVerifyingKey } from "../src/signing.js";
import { verifyToken } from "../src/token.js";
import { makeTestDatabase } from "./support/d1.mjs";
import { makeKeypair } from "./support/keys.mjs";

const NOW = 1767225600; // 2026-01-01T00:00:00Z, whole seconds, fixed
const MAC_A = "0123456789abcdef0123456789abcdef";
const MAC_B = "fedcba9876543210fedcba9876543210";
const MAC_C = "00112233445566778899aabbccddeeff";

async function harness({ mail = () => true } = {}) {
  const { privateBase64, publicBase64 } = makeKeypair();
  const db = makeTestDatabase();
  const store = new Store(db);
  const sent = [];
  let counter = 0;

  return {
    store,
    sent,
    publicBase64,
    signingKey: await importSigningKey(privateBase64),
    async verifying() {
      return importVerifyingKey(publicBase64);
    },
    async call({ email = "someone@example.com", device = MAC_A, now = NOW, clientIP = "203.0.113.7" } = {}) {
      return activate({
        body: { device, email },
        store,
        now,
        clientIP,
        signingKey: this.signingKey,
        mailer: {
          async send(message) {
            sent.push(message);
            return mail(message);
          },
        },
        log: () => {},
        uuid: () => `00000000-0000-4000-8000-${String(counter++).padStart(12, "0")}`,
      });
    },
    async raw(body, extras = {}) {
      return activate({
        body,
        store,
        now: NOW,
        clientIP: "203.0.113.7",
        signingKey: this.signingKey,
        mailer: { async send() { return true; } },
        log: () => {},
        uuid: () => `00000000-0000-4000-8000-${String(counter++).padStart(12, "0")}`,
        ...extras,
      });
    },
  };
}

// MARK: - The trial path

test("an address nobody has seen gets a trial key for this Mac", async () => {
  const h = await harness();
  const result = await h.call();

  assert.equal(result.status, 200);
  assert.match(result.body.key, /^LD1\./);

  const payload = await verifyToken(result.body.key, await h.verifying());
  assert.equal(payload.kind, "trial");
  assert.equal(payload.device, MAC_A);
  assert.equal(payload.email, "someone@example.com");
  assert.equal(payload.issued, NOW);
  assert.equal(payload.expires, NOW + TRIAL_SECONDS);
});

test("the key is mailed as well as returned", async () => {
  const h = await harness();
  const result = await h.call();
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].to, "someone@example.com");
  assert.ok(h.sent[0].text.includes(result.body.key));
});

test("pressing the button twice mails one key and spends one device slot", async () => {
  const h = await harness();
  const first = await h.call();
  const second = await h.call();

  assert.equal(first.body.key, second.body.key);
  assert.equal(h.sent.length, 1);
  assert.equal(await h.store.liveSlotCount((await h.store.strongestLicense("someone@example.com", NOW)).id), 1);
});

test("a mailer that failed is tried again on the next press", async () => {
  let deliver = false;
  const h = await harness({ mail: () => deliver });
  await h.call();
  deliver = true;
  await h.call();
  assert.equal(h.sent.length, 2);

  // And once it has actually gone out, it stops.
  await h.call();
  assert.equal(h.sent.length, 2);
});

test("a mailer that throws does not fail the activation", async () => {
  const h = await harness({
    mail: () => {
      throw new Error("provider down");
    },
  });
  const result = await h.call();
  assert.equal(result.status, 200);
});

test("capitalisation is not a second customer, and not a second key", async () => {
  const h = await harness();
  const first = await h.call({ email: "Someone@Example.com" });
  const second = await h.call({ email: "someone@example.com" });
  assert.equal(first.body.key, second.body.key);
  assert.equal((await verifyToken(first.body.key, await h.verifying())).email, "someone@example.com");
});

test("a second trial on the same address is refused with a sentence that names the offers", async () => {
  const h = await harness();
  await h.call();
  // The trial has run out; the address comes back for another one.
  const later = await h.call({ now: NOW + TRIAL_SECONDS + 1, device: MAC_B });

  assert.equal(later.status, 422);
  assert.equal(later.body.error, "trial_used");
  assert.match(later.body.message, /99/);
});

test("a second trial on the same Mac under a new address is refused too", async () => {
  const h = await harness();
  await h.call({ email: "first@example.com" });
  const again = await h.call({ email: "second@example.com", now: NOW + TRIAL_SECONDS + 1 });

  assert.equal(again.status, 422);
  assert.equal(again.body.error, "trial_used");
});

// MARK: - The two Macs

test("a second Mac gets its own key, and a third is refused", async () => {
  const h = await harness();
  const first = await h.call({ device: MAC_A });
  const second = await h.call({ device: MAC_B });
  const third = await h.call({ device: MAC_C });

  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.notEqual(first.body.key, second.body.key);
  assert.equal((await verifyToken(second.body.key, await h.verifying())).device, MAC_B);

  assert.equal(third.status, 409);
  assert.equal(third.body.error, "device_limit");
  assert.equal(DEVICE_LIMIT, 2);
});

test("releasing one of the two lets the third in", async () => {
  const h = await harness();
  await h.call({ device: MAC_A });
  await h.call({ device: MAC_B });

  const license = await h.store.strongestLicense("someone@example.com", NOW);
  await h.store.releaseSlot(license.id, MAC_A, NOW + 10);

  const third = await h.call({ device: MAC_C, now: NOW + 20 });
  assert.equal(third.status, 200);
  assert.equal((await verifyToken(third.body.key, await h.verifying())).device, MAC_C);
});

// MARK: - What is owned decides what comes back

test("a purchase on the address turns the same call into a lifetime key", async () => {
  const h = await harness();
  await h.store.createLicense({
    id: "bought",
    email: "someone@example.com",
    kind: "lifetime",
    issuedAt: NOW,
    expiresAt: null,
    providerOrderID: "order_1",
  });

  const result = await h.call();
  const payload = await verifyToken(result.body.key, await h.verifying());
  assert.equal(payload.kind, "lifetime");
  assert.equal(payload.expires, undefined);
});

test("a lifetime license outranks a live trial on the same address", async () => {
  const h = await harness();
  await h.call(); // trial
  await h.store.createLicense({ id: "bought", email: "someone@example.com", kind: "lifetime", issuedAt: NOW, expiresAt: null });

  const result = await h.call();
  assert.equal((await verifyToken(result.body.key, await h.verifying())).kind, "lifetime");
});

test("an expired annual is not an entitlement", async () => {
  const h = await harness();
  await h.store.createLicense({
    id: "lapsed",
    email: "someone@example.com",
    kind: "annual",
    issuedAt: NOW - 400 * 86400,
    expiresAt: NOW - 86400,
  });

  // Nothing live, and this address has never had a trial, so it gets one.
  const result = await h.call();
  assert.equal((await verifyToken(result.body.key, await h.verifying())).kind, "trial");
});

test("a refunded license issues no further paid key, and the key already out keeps working", async () => {
  const h = await harness();
  await h.store.createLicense({ id: "bought", email: "someone@example.com", kind: "lifetime", issuedAt: NOW, expiresAt: null });
  const issued = await h.call();
  assert.equal(issued.status, 200);

  await h.store.killLicense("bought");

  // Nothing paid comes out of this address again. What the caller gets is what
  // an address with nothing on it gets — a trial, once — which is the same
  // answer a stranger would have had, and no worse.
  const after = await h.call({ device: MAC_B });
  assert.equal((await verifyToken(after.body.key, await h.verifying())).kind, "trial");

  // And the key that is already on the customer's Mac still verifies. That is
  // the bill for an offline check, and Phase 6 paid it knowingly: a revocation
  // check in the app would trade the product's central promise for a rounding
  // error in fraud.
  assert.notEqual(await verifyToken(issued.body.key, await h.verifying()), null);
});

test("a renewal hands the same Mac a fresh key without spending a second slot", async () => {
  const h = await harness();
  await h.store.createLicense({
    id: "annual",
    email: "someone@example.com",
    kind: "annual",
    issuedAt: NOW,
    expiresAt: NOW + 365 * 86400,
  });
  const first = await h.call();

  await h.store.extendLicense({ id: "annual", kind: "annual", expiresAt: NOW + 730 * 86400 });
  const second = await h.call({ now: NOW + 10 });

  assert.notEqual(first.body.key, second.body.key);
  assert.equal((await verifyToken(second.body.key, await h.verifying())).expires, NOW + 730 * 86400);
  assert.equal(await h.store.liveSlotCount("annual"), 1);
  assert.equal(h.sent.length, 2);
});

// MARK: - Refusals

test("an address that is not one is refused as invalid_email", async () => {
  const h = await harness();
  for (const email of ["", "   ", "someone", "someone@", "@example.com", "someone@example", "a b@example.com", 7, null]) {
    const result = await h.raw({ device: MAC_A, email });
    assert.equal(result.status, 400, `accepted ${JSON.stringify(email)}`);
    assert.equal(result.body.error, "invalid_email");
  }
});

test("an identifier that is not 32 lowercase hex is refused, and says what to do", async () => {
  const h = await harness();
  for (const device of ["", "abc", MAC_A.toUpperCase(), `${MAC_A}0`, 7, null]) {
    const result = await h.raw({ device, email: "someone@example.com" });
    assert.equal(result.status, 400, `accepted ${JSON.stringify(device)}`);
    assert.equal(result.body.error, "invalid_device");
    assert.match(result.body.message, /Update Witness/);
  }
});

test("nothing is stored for a refused request", async () => {
  const h = await harness();
  await h.raw({ device: MAC_A, email: "not-an-address" });
  assert.equal(await h.store.strongestLicense("not-an-address", NOW), null);
  assert.equal(await h.store.deviceHasHadTrial(MAC_A), false);
});

// MARK: - Rate limiting

test("a Mac asking over and over is asked to wait, and is not refused", async () => {
  const h = await harness();
  let last;
  for (let i = 0; i <= RATE_LIMITS.device.limit; i += 1) {
    last = await h.call({ email: `someone${i}@example.com` });
  }
  assert.equal(last.status, 429);
  assert.equal(last.headers["Retry-After"], "60");
});

test("one address block cannot exhaust the service for everyone", async () => {
  const h = await harness();
  let last;
  for (let i = 0; i <= RATE_LIMITS.address.limit; i += 1) {
    last = await h.call({ email: `someone${i}@example.com`, device: MAC_A, clientIP: "198.51.100.4" });
  }
  assert.equal(last.status, 429);

  const elsewhere = await h.call({ email: "elsewhere@example.com", device: MAC_B, clientIP: "198.51.100.5" });
  assert.notEqual(elsewhere.status, 429);
});

test("the window moves, so a rate limit is a wait rather than a wall", async () => {
  const h = await harness();
  for (let i = 0; i <= RATE_LIMITS.device.limit; i += 1) {
    await h.call({ email: `someone${i}@example.com` });
  }
  const later = await h.call({ now: NOW + RATE_LIMITS.device.window + 1 });
  assert.notEqual(later.status, 429);
});

test("counters do not outlive a day", async () => {
  const h = await harness();
  await h.call();
  await h.store.forgetOldCounters(NOW + 86400 + RATE_LIMITS.device.window);
  assert.equal(await h.store.first("SELECT COUNT(*) AS count FROM rate_counters").then((row) => row.count), 0);
});

// MARK: - What is stored

test("the tables hold what PHASE_8 says they hold and nothing else", async () => {
  const h = await harness();
  await h.call();

  const columns = async (table) =>
    (await h.store.all(`PRAGMA table_info(${table})`)).map((row) => row.name).sort();

  assert.deepEqual(await columns("licenses"), [
    "created_at",
    "email",
    "expires_at",
    "id",
    "issued_at",
    "kind",
    "provider_order_id",
    "status",
  ]);
  assert.deepEqual(await columns("device_slots"), [
    "device",
    "expires_at",
    "issued_at",
    "key_id",
    "license_id",
    "mailed_at",
    "released_at",
  ]);
  assert.deepEqual(await columns("rate_counters"), ["bucket", "count", "window_start"]);
});
