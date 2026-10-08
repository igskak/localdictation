// The event route, held to the list rather than to its intentions.
//
// Every assertion here is a sentence in `docs/PRIVACY.md`: nine event names,
// five fields, no address, ninety days. The route is the half of that boundary
// this repository can still change after a build has shipped, which is why it
// validates what a client already validated.

import test from "node:test";
import assert from "node:assert/strict";

import worker from "../src/worker.js";
import { ALLOWED_EVENTS, RATE_LIMITS, RETENTION_SECONDS, record } from "../src/events.js";
import { createAnalytics } from "../src/analytics.js";
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

test("all nine of the listed events are accepted and nothing else is", async () => {
  const env = makeEnv();
  assert.deepEqual(
    [...ALLOWED_EVENTS].sort(),
    [
      "activation_requested",
      "dictation_blocked_by_model",
      "installed",
      "microphone_denied",
      "model_download_started",
      "model_failed",
      "model_ready",
      "paywall_shown",
      "trial_started",
    ],
  );

  for (const event of ALLOWED_EVENTS) {
    const response = await worker.fetch(post(body({ event })), env, {});
    assert.equal(response.status, 202, event);
  }

  // The six the app builds but does not send. A client that started sending
  // one is refused here rather than collected quietly.
  for (const event of [
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

/// The table's own `CHECK` is the third copy of the list, and the one that a
/// worker deployed ahead of its migration would run into. It is asserted here
/// because the test database runs the real `schema.sql`: a name accepted by the
/// route and refused by the table would answer 202 and store nothing.
test("the table accepts every name the route does", async () => {
  const env = makeEnv();
  const store = new Store(env.DB);

  for (const event of ALLOWED_EVENTS) {
    await store.recordEvent({
      installID: INSTALL,
      event,
      qualifier: null,
      appVersion: "0.6.9",
      systemVersion: "15.0",
      at: 1_700_000_000,
    });
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

  // The two setup events that carry one, each from its own vocabulary — and a
  // bucket borrowed by the wrong event is refused like any other invention.
  const wait = await worker.fetch(post(body({ event: "model_ready", qualifier: "underFiveMinutes" })), env, {});
  assert.equal(wait.status, 202);

  const failure = await worker.fetch(post(body({ event: "model_failed", qualifier: "storage" })), env, {});
  assert.equal(failure.status, 202);

  const borrowed = await worker.fetch(post(body({ event: "model_ready", qualifier: "storage" })), env, {});
  assert.equal(borrowed.status, 400);
  assert.equal((await borrowed.json()).error, "unknown_qualifier");

  // A duration where a bucket belongs. The app cannot produce one; this is what
  // happens if something else tries.
  const seconds = await worker.fetch(post(body({ event: "model_ready", qualifier: "743" })), env, {});
  assert.equal(seconds.status, 400);

  assert.equal((await rows(env)).length, 3);
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

// MARK: - What is passed on to PostHog

function forwarding() {
  const sent = [];
  const analytics = createAnalytics(
    { POSTHOG_KEY: "phc_test" },
    { fetcher: async (url, init) => { sent.push({ url, body: JSON.parse(init.body) }); return { ok: true, status: 200 }; } },
  );
  const store = new Store(makeTestDatabase());
  const run = (payload, now = 1767225600) =>
    record({ body: payload, store, now, clientIP: "203.0.113.7", log: () => {}, analytics });
  return { sent, run, store };
}

test("an accepted event reaches PostHog with the install id, its qualifier and the two versions, and nothing else", async () => {
  const { sent, run } = forwarding();
  const result = await run(body({ event: "model_failed", qualifier: "network" }));

  assert.equal(result.status, 202);
  assert.equal(sent.length, 1);
  const { body: wire } = sent[0];
  assert.equal(sent[0].url, "https://eu.i.posthog.com/i/v0/e/");
  assert.equal(wire.event, "model_failed");
  assert.equal(wire.distinct_id, INSTALL);
  assert.equal(wire.timestamp, new Date(1767225600 * 1000).toISOString());
  assert.deepEqual(
    Object.keys(wire.properties).sort(),
    ["$geoip_disable", "$process_person_profile", "app_version", "qualifier", "source", "system_version"],
  );
  assert.equal(wire.properties.qualifier, "network");
  assert.equal(wire.properties.$process_person_profile, false);
  assert.equal(wire.properties.$geoip_disable, true);
  assert.equal(JSON.stringify(wire).includes("203.0.113.7"), false, "an address reached PostHog");
});

test("an event with no qualifier sends no qualifier property", async () => {
  const { sent, run } = forwarding();
  await run(body({ event: "installed" }));
  assert.equal("qualifier" in sent[0].body.properties, false);
});

test("every one of the nine listed events is forwarded under its own name", async () => {
  const { sent, run } = forwarding();
  const qualifiers = { paywall_shown: "trialExpired", model_ready: "underOneMinute", model_failed: "other" };
  for (const event of ALLOWED_EVENTS) await run(body({ event, qualifier: qualifiers[event] }));
  assert.deepEqual(sent.map((s) => s.body.event).sort(), [...ALLOWED_EVENTS].sort());
});

test("an event the route refuses never reaches PostHog", async () => {
  const { sent, run } = forwarding();
  assert.equal((await run(body({ event: "dictation_finished" }))).status, 400);
  assert.equal((await run(body({ event: "paywall_shown", qualifier: "invented" }))).status, 400);
  assert.equal((await run(body({ install_id: "not-a-uuid" }))).status, 400);
  assert.equal(sent.length, 0);
});

test("a rate-limited event is not forwarded either", async () => {
  const { sent, run } = forwarding();
  for (let i = 0; i < RATE_LIMITS.install.limit + 5; i += 1) await run(body({ event: "installed" }));
  assert.equal(sent.length, RATE_LIMITS.install.limit);
});

test("with no PostHog key the route behaves exactly as before", async () => {
  const env = makeEnv();
  const response = await worker.fetch(post(body()), env, {});
  assert.equal(response.status, 202);
  assert.equal((await rows(env)).length, 1);
});
