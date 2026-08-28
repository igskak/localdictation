// The router, and the shape of every answer that leaves this service.
//
// `HTTPActivationBackend` refuses a 200 that is not a key, refuses anything over
// 8 KB, and expects one origin with no redirect. So the assertions here are
// about envelopes rather than about licensing: a service that answers correctly
// in the wrong wrapper is a service the app can only report as broken.

import test from "node:test";
import assert from "node:assert/strict";

import worker from "../src/worker.js";
import { makeTestDatabase } from "./support/d1.mjs";
import { makeKeypair } from "./support/keys.mjs";

const MAC = "0123456789abcdef0123456789abcdef";

function makeEnv(overrides = {}) {
  const { privateBase64, publicBase64 } = makeKeypair();
  return {
    DB: makeTestDatabase(),
    LICENSE_SIGNING_KEY: privateBase64,
    LICENSE_PUBLIC_KEY: publicBase64,
    MAIL_PROVIDER: "none",
    ...overrides,
  };
}

const post = (path, body, headers = {}) =>
  new Request(`https://activation.example.com${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

test("a key comes back as JSON, uncached, with no redirect", async () => {
  const response = await worker.fetch(post("/v1/activate", { device: MAC, email: "someone@example.com" }), makeEnv(), {});

  assert.equal(response.status, 200);
  assert.equal(response.redirected, false);
  assert.match(response.headers.get("Content-Type"), /application\/json/);
  assert.equal(response.headers.get("Cache-Control"), "no-store");

  const body = await response.json();
  assert.match(body.key, /^LD1\./);
  assert.ok(JSON.stringify(body).length < 8 * 1024, "the app refuses anything larger");
});

test("the wrong method is a refusal rather than a surprise", async () => {
  const env = makeEnv();
  for (const [path, method] of [
    ["/v1/activate", "GET"],
    ["/v1/devices/release", "GET"],
    ["/v1/purchases/webhook", "GET"],
    ["/v1/health", "POST"],
  ]) {
    const response = await worker.fetch(new Request(`https://activation.example.com${path}`, { method }), env, {});
    assert.equal(response.status, 405, `${method} ${path}`);
  }
});

test("an unknown path is JSON too", async () => {
  const response = await worker.fetch(new Request("https://activation.example.com/"), makeEnv(), {});
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: "not_found" });
});

test("a body that is not JSON, or is enormous, never reaches the licensing code", async () => {
  const env = makeEnv();

  const garbage = await worker.fetch(post("/v1/activate", "<html>hello</html>"), env, {});
  assert.equal(garbage.status, 400);

  const enormous = await worker.fetch(
    post("/v1/activate", { device: MAC, email: "someone@example.com", padding: "x".repeat(8 * 1024) }),
    env,
    {},
  );
  assert.equal(enormous.status, 400);
});

test("health reports whether this deployment signs keys the app will accept", async () => {
  const good = await worker.fetch(new Request("https://activation.example.com/v1/health"), makeEnv(), {});
  assert.equal(good.status, 200);
  assert.deepEqual(await good.json(), {
    status: "ok",
    database: true,
    signing_key: true,
    authority_match: true,
    mail_provider: "none",
  });

  // The failure that matters is silent: a wrong secret issues keys that verify
  // on nobody's Mac while everything else looks fine.
  const stranger = makeKeypair();
  const wrong = await worker.fetch(
    new Request("https://activation.example.com/v1/health"),
    makeEnv({ LICENSE_PUBLIC_KEY: stranger.publicBase64 }),
    {},
  );
  assert.equal(wrong.status, 503);
  assert.equal((await wrong.json()).authority_match, false);
});

test("a webhook with no provider configured says so rather than accepting money quietly", async () => {
  const response = await worker.fetch(post("/v1/purchases/webhook", { id: "evt_1" }), makeEnv(), {});
  assert.equal(response.status, 503);
});

test("a webhook without a good signature is refused before it is parsed", async () => {
  const env = makeEnv({ PAYMENT_PROVIDER: "stripe", WEBHOOK_SECRET: "whsec_test" });
  const response = await worker.fetch(
    post("/v1/purchases/webhook", { id: "evt_1", type: "checkout.session.completed" }, { "Stripe-Signature": "t=1,v1=00" }),
    env,
    {},
  );
  assert.equal(response.status, 401);
});
