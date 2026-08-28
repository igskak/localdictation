// Freeing one of the two Macs a license covers.
//
// The property being defended here is that possession of the key is the proof.
// An endpoint that freed a slot on an address alone would let anyone who can
// guess a stranger's email evict their Mac, and every test below is one way of
// trying to do exactly that.

import test from "node:test";
import assert from "node:assert/strict";

import { activate } from "../src/activate.js";
import { release } from "../src/release.js";
import { Store } from "../src/store.js";
import { importSigningKey, importVerifyingKey } from "../src/signing.js";
import { issueToken } from "../src/token.js";
import { makeTestDatabase } from "./support/d1.mjs";
import { makeKeypair } from "./support/keys.mjs";

const NOW = 1767225600;
const MAC_A = "0123456789abcdef0123456789abcdef";
const MAC_B = "fedcba9876543210fedcba9876543210";
const MAC_C = "00112233445566778899aabbccddeeff";
const EMAIL = "someone@example.com";

async function harness() {
  const { privateBase64, publicBase64 } = makeKeypair();
  const store = new Store(makeTestDatabase());
  let counter = 0;

  const signingKey = await importSigningKey(privateBase64);
  const verifyingKey = await importVerifyingKey(publicBase64);

  return {
    store,
    signingKey,
    verifyingKey,
    publicBase64,
    async activate({ email = EMAIL, device = MAC_A, now = NOW } = {}) {
      return activate({
        body: { device, email },
        store,
        now,
        clientIP: `203.0.113.${counter % 200}`,
        signingKey,
        mailer: { async send() { return true; } },
        log: () => {},
        uuid: () => `00000000-0000-4000-8000-${String(counter++).padStart(12, "0")}`,
      });
    },
    async release(body, { now = NOW, clientIP = "203.0.113.7" } = {}) {
      return release({ body, store, now, clientIP, verifyingKey, log: () => {} });
    },
  };
}

test("a key releases the Mac it names, and a third Mac gets in", async () => {
  const h = await harness();
  const first = await h.activate({ device: MAC_A });
  await h.activate({ device: MAC_B });
  assert.equal((await h.activate({ device: MAC_C })).status, 409);

  const released = await h.release({ device: MAC_A, key: first.body.key });
  assert.equal(released.status, 200);
  assert.equal(released.body.released, true);

  assert.equal((await h.activate({ device: MAC_C })).status, 200);
});

test("releasing twice is not an error: a slot that is gone is a slot that was released", async () => {
  const h = await harness();
  const issued = await h.activate();
  assert.equal((await h.release({ device: MAC_A, key: issued.body.key })).status, 200);
  assert.equal((await h.release({ device: MAC_A, key: issued.body.key })).status, 200);
});

test("a key for one Mac cannot release another", async () => {
  const h = await harness();
  const first = await h.activate({ device: MAC_A });
  await h.activate({ device: MAC_B });

  const refused = await h.release({ device: MAC_B, key: first.body.key });
  assert.equal(refused.status, 403);
  assert.equal(refused.body.error, "device_mismatch");

  // And the slot it tried to take is still occupied.
  const license = await h.store.strongestLicense(EMAIL, NOW);
  assert.equal(await h.store.liveSlotCount(license.id), 2);
});

test("a key from another authority releases nothing", async () => {
  const h = await harness();
  await h.activate({ device: MAC_A });

  const stranger = makeKeypair();
  const forged = await issueToken(
    { device: MAC_A, email: EMAIL, expires: NOW + 86400, id: "forged", issued: NOW, kind: "trial" },
    await importSigningKey(stranger.privateBase64),
  );

  const refused = await h.release({ device: MAC_A, key: forged });
  assert.equal(refused.status, 401);
  assert.equal(refused.body.error, "bad_key");

  const license = await h.store.strongestLicense(EMAIL, NOW);
  assert.equal(await h.store.liveSlotCount(license.id), 1);
});

test("an edited key releases nothing", async () => {
  const h = await harness();
  const issued = await h.activate({ device: MAC_A });
  const parts = issued.body.key.split(".");
  const edited = `${parts[0]}.${parts[1]}x.${parts[2]}`;

  assert.equal((await h.release({ device: MAC_A, key: edited })).status, 401);
});

test("a well-formed key this service never issued is not a record it has", async () => {
  const h = await harness();
  const key = await issueToken(
    { device: MAC_A, email: "nobody@example.com", expires: NOW + 86400, id: "never-issued", issued: NOW, kind: "trial" },
    h.signingKey,
  );

  const answer = await h.release({ device: MAC_A, key });
  assert.equal(answer.status, 404);
  assert.equal(answer.body.error, "unknown_key");
});

test("a request missing a half is refused before anything is looked up", async () => {
  const h = await harness();
  for (const body of [{}, { device: MAC_A }, { key: "LD1.a.b" }, { device: "nope", key: "LD1.a.b" }, null]) {
    const answer = await h.release(body);
    assert.equal(answer.status, 400, `accepted ${JSON.stringify(body)}`);
  }
});

test("releasing is rate-limited per Mac", async () => {
  const h = await harness();
  const issued = await h.activate();
  let last;
  for (let i = 0; i <= 10; i += 1) {
    last = await h.release({ device: MAC_A, key: issued.body.key });
  }
  assert.equal(last.status, 429);
});

test("a released Mac can activate again and take its slot back", async () => {
  const h = await harness();
  const issued = await h.activate({ device: MAC_A });
  await h.release({ device: MAC_A, key: issued.body.key });

  const again = await h.activate({ device: MAC_A, now: NOW + 60 });
  assert.equal(again.status, 200);
  const license = await h.store.strongestLicense(EMAIL, NOW);
  assert.equal(await h.store.liveSlotCount(license.id), 1);
});
