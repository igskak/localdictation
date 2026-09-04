// Asks a *running* activation service for keys and writes them where the app's
// test suite will read them.
//
// `docs/PHASE_8.md`: "Before the service issues a key to anyone, have it produce
// one key of each kind into a fixture file and add a test beside
// `LicenseIssuerToolTests` that reads them through the shipping
// `LicenseKey.verify`." `parity-fixture.mjs` does that for the *source*; this
// does it for a *deployment*, which is the half that catches a runtime
// difference. Everything in this service is tested under Node and production is
// workerd, and Ed25519, base64 and JSON are three places those could differ by
// a byte.
//
//   node tools/live-fixture.mjs --url https://host \
//     --pair someone@example.com:0123456789abcdef0123456789abcdef
//
// Then run the app's test suite: ActivationServiceParityTests reads
// fixtures/live.json whenever it exists, and ignores it when it does not.
//
// One `--pair` per key wanted. What kind comes back is whatever that address
// owns, so a fresh deployment gives trials — seed a purchase to get the others.

import { writeFileSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

function argument(name, fallback = null) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && index + 1 < process.argv.length ? process.argv[index + 1] : fallback;
}

function pairs() {
  const found = [];
  process.argv.forEach((value, index) => {
    if (value !== "--pair") return;
    const raw = process.argv[index + 1] ?? "";
    const at = raw.lastIndexOf(":");
    if (at <= 0) throw new Error(`--pair wants email:device, got "${raw}"`);
    found.push({ email: raw.slice(0, at), device: raw.slice(at + 1) });
  });
  return found;
}

/// The public half the fixture is verified against. Defaults to the one in
/// wrangler.toml, which is the deployment's own.
function configuredPublicKey() {
  const toml = readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8");
  return toml.match(/^LICENSE_PUBLIC_KEY\s*=\s*"([^"]+)"/m)?.[1] ?? null;
}

function decodePayload(token) {
  const part = token.split(".")[1];
  const padded = part.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (part.length % 4)) % 4);
  return JSON.parse(Buffer.from(padded, "base64").toString("utf8"));
}

const url = argument("url");
const requested = pairs();
if (!url || requested.length === 0) {
  console.error("usage: node tools/live-fixture.mjs --url <base> --pair <email>:<device> [--pair ...]");
  process.exit(1);
}

const publicKeyBase64 = argument("public-key", configuredPublicKey());
if (!publicKeyBase64) {
  console.error("no --public-key given and none found in wrangler.toml");
  process.exit(1);
}

const keys = [];
for (const { email, device } of requested) {
  const response = await fetch(`${url.replace(/\/$/, "")}/v1/activate`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", "User-Agent": "LocalDictation" },
    body: JSON.stringify({ device, email }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body.key) {
    console.error(`${email}: ${response.status} ${JSON.stringify(body)}`);
    process.exit(1);
  }
  const payload = decodePayload(body.key);
  keys.push({
    kind: payload.kind,
    id: payload.id,
    issued: payload.issued,
    ...(payload.expires === undefined ? {} : { expires: payload.expires }),
    token: body.key,
    device: payload.device,
    email: payload.email,
  });
  console.log(`${payload.kind} key for ${payload.device}`);
}

const out = argument("out", fileURLToPath(new URL("../fixtures/live.json", import.meta.url)));
writeFileSync(
  out,
  `${JSON.stringify(
    {
      note: `Taken from ${url}. Not committed: it is about one deployment at one moment.`,
      device: keys[0].device,
      email: keys[0].email,
      publicKeyBase64,
      keys,
    },
    null,
    2,
  )}\n`,
);
console.log(`wrote ${out}`);
