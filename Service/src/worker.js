// The activation service. Two endpoints, a webhook, and a health check.
//
// It is deliberately small. Everything hard about licensing in this product was
// made a signature in Phase 6 — the app verifies offline, against a public key
// it carries — so this side is a table, a signer, and a mailer, and it can be
// down for a day without a single paid copy noticing.

import { json, readJSON, clientAddress } from "./http.js";
import { Store } from "./store.js";
import { importSigningKey, signingKeyMatchesAuthority } from "./signing.js";
import { activate } from "./activate.js";
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
