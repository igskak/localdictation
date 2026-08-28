// The activation service. Two endpoints, a webhook, and a health check.
//
// It is deliberately small. Everything hard about licensing in this product was
// made a signature in Phase 6 — the app verifies offline, against a public key
// it carries — so this side is a table, a signer, and a mailer, and it can be
// down for a day without a single paid copy noticing.

import { json, readJSON, clientAddress } from "./http.js";
import { Store } from "./store.js";
import { importSigningKey, importVerifyingKey, signingKeyMatchesAuthority } from "./signing.js";
import { activate } from "./activate.js";
import { release } from "./release.js";
import { handleEvent } from "./webhook.js";
import { providerFor, signatureHeader } from "./providers.js";
import { createMailer } from "./mailer.js";

/// Structured, one line per event, and never an address. The key id is what a
/// support conversation is conducted in; a log that carries the customer's
/// email is a log that has to be retained like the licence table itself.
function makeLog(route) {
  return (message, fields = {}) => {
    console.log(JSON.stringify({ route, message, ...fields }));
  };
}

let cachedSigningKey = null;
let cachedSigningSecret = null;

async function signingKey(env) {
  if (!env.LICENSE_SIGNING_KEY) throw new Error("LICENSE_SIGNING_KEY is not set");
  if (cachedSigningSecret !== env.LICENSE_SIGNING_KEY) {
    cachedSigningKey = await importSigningKey(env.LICENSE_SIGNING_KEY);
    cachedSigningSecret = env.LICENSE_SIGNING_KEY;
  }
  return cachedSigningKey;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const route = url.pathname;

    if (route === "/v1/health") {
      if (request.method !== "GET") return json(405, { error: "method_not_allowed" });
      return handleHealth(env);
    }

    if (route === "/v1/activate") {
      if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
      return handleActivate(request, env, ctx);
    }

    if (route === "/v1/devices/release") {
      if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
      return handleRelease(request, env, ctx);
    }

    if (route === "/v1/purchases/webhook") {
      if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
      return handleWebhook(request, env);
    }

    return json(404, { error: "not_found" });
  },
};

async function handleActivate(request, env, ctx) {
  const log = makeLog("/v1/activate");
  const body = await readJSON(request);
  if (!body) return json(400, { error: "invalid_request", message: "That request was not something this service could read." });

  const store = new Store(env.DB);
  const now = Math.floor(Date.now() / 1000);

  let result;
  try {
    result = await activate({
      body,
      store,
      now,
      clientIP: clientAddress(request),
      signingKey: await signingKey(env),
      mailer: createMailer(env, log),
      log,
    });
  } catch (error) {
    // The user is told to come back, which is true: nothing was issued and
    // nothing was spent.
    log("activation failed", { reason: String(error?.message ?? "error") });
    return json(500, { error: "internal" });
  }

  // Counters are the only place an IP appears and they do not outlive a day.
  // Swept after the answer has gone out rather than in front of it.
  ctx?.waitUntil?.(store.forgetOldCounters(now).catch(() => {}));

  return json(result.status, result.body, result.headers ?? {});
}

async function handleRelease(request, env, ctx) {
  const log = makeLog("/v1/devices/release");
  const body = await readJSON(request);
  if (!body) return json(400, { error: "invalid_request", message: "That request was not something this service could read." });

  const store = new Store(env.DB);
  const now = Math.floor(Date.now() / 1000);

  let result;
  try {
    result = await release({
      body,
      store,
      now,
      clientIP: clientAddress(request),
      // The public half, which is all this check needs. Nothing about freeing a
      // slot requires the ability to sign.
      verifyingKey: await importVerifyingKey(env.LICENSE_PUBLIC_KEY ?? ""),
      log,
    });
  } catch (error) {
    log("release failed", { reason: String(error?.message ?? "error") });
    return json(500, { error: "internal" });
  }

  ctx?.waitUntil?.(store.forgetOldCounters(now).catch(() => {}));

  return json(result.status, result.body, result.headers ?? {});
}

/// The signature is over the body **as it arrived**, so this is the one route
/// that reads text before it reads JSON. Parsing and re-serializing first is how
/// a signature check quietly becomes decoration.
async function handleWebhook(request, env) {
  const log = makeLog("/v1/purchases/webhook");
  const provider = providerFor(env);
  if (!provider) {
    log("no payment provider configured");
    return json(503, { error: "not_configured" });
  }

  const body = await request.text();
  if (body.length > MAXIMUM_WEBHOOK_BYTES) return json(413, { error: "too_large" });

  const now = Math.floor(Date.now() / 1000);
  const verified = await provider.verify({
    header: signatureHeader(provider, request),
    body,
    secret: env.WEBHOOK_SECRET,
    now,
  });
  if (!verified) {
    log("signature refused", { provider: provider.name });
    return json(401, { error: "bad_signature" });
  }

  let event;
  try {
    event = JSON.parse(body);
  } catch {
    return json(400, { error: "invalid_request" });
  }

  try {
    const result = await handleEvent({
      event,
      provider,
      env,
      store: new Store(env.DB),
      now,
      mailer: createMailer(env, log),
      log,
    });
    return json(result.status, result.body);
  } catch (error) {
    // A 500 is what makes the provider redeliver, which is what should happen:
    // the event id has been claimed only if the write got that far.
    log("webhook failed", { reason: String(error?.message ?? "error") });
    return json(500, { error: "internal" });
  }
}

/// Providers send fat events. This is far above any of them and far below
/// anything worth reading into memory by accident.
const MAXIMUM_WEBHOOK_BYTES = 128 * 1024;

/// Deliberately more than "the process is running": the failure that matters is
/// silent. A wrong signing secret issues keys that verify on nobody's Mac while
/// every dashboard stays green.
async function handleHealth(env) {
  const checks = { database: false, signing_key: false, authority_match: false, mail_provider: env.MAIL_PROVIDER ?? "none" };

  try {
    await new Store(env.DB).first("SELECT 1 AS ok");
    checks.database = true;
  } catch {
    checks.database = false;
  }

  try {
    const key = await signingKey(env);
    checks.signing_key = true;
    checks.authority_match = env.LICENSE_PUBLIC_KEY
      ? await signingKeyMatchesAuthority(key, env.LICENSE_PUBLIC_KEY)
      : false;
  } catch {
    checks.signing_key = false;
  }

  const healthy = checks.database && checks.signing_key && checks.authority_match;
  return json(healthy ? 200 : 503, { status: healthy ? "ok" : "degraded", ...checks });
}
