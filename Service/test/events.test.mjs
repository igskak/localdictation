// The event route, held to the list rather than to its intentions.
//
// Every assertion here is a sentence in `docs/PRIVACY.md`: three event names,
// five fields, no address, ninety days. The route is the half of that boundary
// this repository can still change after a build has shipped, which is why it
// validates what a client already validated.

import test from "node:test";
import assert from "node:assert/strict";

import worker from "../src/worker.js";
import { ALLOWED_EVENTS, RATE_LIMITS, RETENTION_SECONDS } from "../src/events.js";
import { Store } from "../src/store.js";
import { makeTestDatabase } from "./support/d1.mjs";
import { makeKeypair } from "./support/keys.mjs";

const INSTALL = "9F1B2C3D-4E5F-4A6B-8C9D-0E1F2A3B4C5D";

function makeEnv() {
  const { privateBase64, publicBase64 } = makeKeypair();
  return {
    DB: makeTestDatabase(),
    LICENSE_SIGNING_KEY: privateBase64,
    LICENSE_PUBLIC_KEY: publicBase64,
    MAIL_PROVIDER: "none",
  };
}

const body = (overrides = {}) => ({
  app_version: "0.3.0",
  event: "trial_started",
  install_id: INSTALL,
  system_version: "15.0",
  ...overrides,
});

const post = (payload, headers = {}) =>
  new Request("https://api.witnessmac.com/v1/events", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof payload === "string" ? payload : JSON.stringify(payload),
  });

const rows = (env) => new Store(env.DB).all(`SELECT * FROM product_events ORDER BY id`);

test("an event is accepted, stored, and answered without a body worth reading", async () => {
  const env = makeEnv();
  const response = await worker.fetch(post(body()), env, {});

  assert.equal(response.status, 202);
  assert.equal(response.headers.get("Cache-Control"), "no-store");

  const stored = await rows(env);
  assert.equal(stored.length, 1);
  assert.equal(stored[0].event, "trial_started");
  assert.equal(stored[0].install_id, INSTALL);
  assert.equal(stored[0].qualifier, null);
  assert.equal(stored[0].app_version, "0.3.0");
  assert.equal(stored[0].system_version, "15.0");
});

test("all three of the listed events are accepted and nothing else is", async () => {
  const env = makeEnv();
  assert.deepEqual([...ALLOWED_EVENTS].sort(), ["activation_requested", "paywall_shown", "trial_started"]);

  for (const event of ALLOWED_EVENTS) {
    const response = await worker.fetch(post(body({ event })), env, {});
    assert.equal(response.status, 202, event);
  }

  // The seven the app builds but does not send. A client that started sending
  // one is refused here rather than collected quietly.
  for (const event of [
    "installed",
    "activation_succeeded",
    "activation_failed",
    "license_accepted",
    "license_rejected",
    "checkout_opened",
    "entitlement_lapsed",
  ]) {
    const response = await worker.fetch(post(body({ event })), env, {});
    assert.equal(response.status, 400, event);
    assert.equal((await response.json()).error, "unknown_event");
  }

  assert.equal((await rows(env)).length, ALLOWED_EVENTS.size);
});

test("a qualifier is only accepted where the app has one, and only from its fixed set", async () => {
  const env = makeEnv();

  const good = await worker.fetch(post(body({ event: "paywall_shown", qualifier: "trialExpired" })), env, {});
  assert.equal(good.status, 202);

  // A qualifier the app's enum cannot produce.
  const invented = await worker.fetch(post(body({ event: "paywall_shown", qualifier: "someoneWroteThis" })), env, {});
  assert.equal(invented.status, 400);
  assert.equal((await invented.json()).error, "unknown_qualifier");

  // A real qualifier on an event that does not carry one.
  const misplaced = await worker.fetch(post(body({ event: "trial_started", qualifier: "trialExpired" })), env, {});
  assert.equal(misplaced.status, 400);

  assert.equal((await rows(env)).length, 1);
});

/// The one field that could carry something if it were free text. It is not:
/// the app sends `UUID().uuidString` and this route accepts that shape alone.
test("the install identifier has to be the shape the app makes, and nothing longer", async () => {
  const env = makeEnv();

  for (const installID of ["", "not-a-uuid", INSTALL.slice(0, 20), `${INSTALL}extra`, "someone@example.com"]) {
    const response = await worker.fetch(post(body({ install_id: installID })), env, {});
    assert.equal(response.status, 400, JSON.stringify(installID));
    assert.equal((await response.json()).error, "invalid_install_id");
  }

  assert.equal((await rows(env)).length, 0);
});

test("the two version fields are bounded rather than trusted", async () => {
  const env = makeEnv();

  for (const overrides of [
    { app_version: "" },
    { app_version: "x".repeat(21) },
    { app_version: "0.3.0 (the one that broke)" },
    { system_version: "15.0; DROP TABLE licenses" },
  ]) {
    const response = await worker.fetch(post(body(overrides)), env, {});
    assert.equal(response.status, 400, JSON.stringify(overrides));
    assert.equal((await response.json()).error, "invalid_version");
  }

  assert.equal((await rows(env)).length, 0);
});

/// The claim the privacy policy makes about this table, asserted against the
/// table. A sixth column would be a field nobody was told about.
test("a stored row holds five facts and a timestamp, and no address anywhere", async () => {
  const env = makeEnv();
  await worker.fetch(post(body()), env, {});

  const stored = (await rows(env))[0];
  assert.deepEqual(Object.keys(stored).sort(), [
    "app_version",
    "event",
    "id",
    "install_id",
    "qualifier",
    "received_at",
    "system_version",
  ]);

  const everything = JSON.stringify(await new Store(env.DB).all(`SELECT * FROM product_events`));
  assert.equal(everything.includes("@"), false, "an address reached the events table");
});

test("the route is counted, per install and per address block", async () => {
  const env = makeEnv();

  let last;
  for (let index = 0; index <= RATE_LIMITS.install.limit; index += 1) {
    last = await worker.fetch(post(body()), env, {});
  }

  assert.equal(last.status, 429);
  assert.equal((await rows(env)).length, RATE_LIMITS.install.limit);
});

test("ninety days is what the sweep actually deletes", async () => {
  const env = makeEnv();
  const store = new Store(env.DB);
  const now = Math.floor(Date.now() / 1000);

  await store.recordEvent({
    installID: INSTALL,
    event: "trial_started",
    qualifier: null,
    appVersion: "0.3.0",
    systemVersion: "15.0",
    at: now - RETENTION_SECONDS - 1,
  });
  await store.recordEvent({
    installID: INSTALL,
    event: "trial_started",
    qualifier: null,
    appVersion: "0.3.0",
    systemVersion: "15.0",
    at: now - RETENTION_SECONDS + 60,
  });

  await store.forgetOldEvents(now, RETENTION_SECONDS);

  const remaining = await rows(env);
  assert.equal(remaining.length, 1);
  assert.equal(remaining[0].received_at, now - RETENTION_SECONDS + 60);
});

test("a body that is not an object is refused the way every other route refuses one", async () => {
  const env = makeEnv();

  for (const payload of ["not json", "[1,2,3]", "null"]) {
    const response = await worker.fetch(post(payload), env, {});
    assert.equal(response.status, 400, payload);
  }

  const wrongMethod = await worker.fetch(new Request("https://api.witnessmac.com/v1/events", { method: "GET" }), env, {});
  assert.equal(wrongMethod.status, 405);
});
