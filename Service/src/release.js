// POST /v1/devices/release — moving a Mac out of the two a license covers.
//
// The proof is the key. Possession of it is the only thing the app holds, and
// an endpoint that freed a slot on an address alone would let anyone who can
// guess an email evict a stranger's Mac. So the signature is checked here,
// server-side, against the same public key the app verifies with.
//
// Idempotent by construction: a slot that is not there is a slot that has been
// released, and saying so is more useful than an error about a state the caller
// already wanted.

import { verifyToken, DEVICE_PATTERN } from "./token.js";
import { RATE_LIMITS } from "./activate.js";

export async function release({ body, store, now, clientIP, verifyingKey, log }) {
  if ((await store.bump(`ip:${clientIP}`, now, RATE_LIMITS.address.window)) > RATE_LIMITS.address.limit) {
    return { status: 429, body: { error: "rate_limited" }, headers: { "Retry-After": "60" } };
  }

  const device = typeof body?.device === "string" ? body.device.trim() : "";
  const key = typeof body?.key === "string" ? body.key.trim() : "";
  if (!DEVICE_PATTERN.test(device) || key.length === 0) {
    return {
      status: 400,
      body: { error: "invalid_request", message: "That release request was missing the Mac or the key it belongs to." },
    };
  }

  if ((await store.bump(`release:${device}`, now, RATE_LIMITS.device.window)) > RATE_LIMITS.device.limit) {
    return { status: 429, body: { error: "rate_limited" }, headers: { "Retry-After": "60" } };
  }

  const payload = await verifyToken(key, verifyingKey);
  if (!payload) {
    return {
      status: 401,
      body: { error: "bad_key", message: "That key did not verify, so nothing was released." },
    };
  }

  // The key names one Mac. Releasing a different one with it would be the same
  // hole read from the inside.
  if (payload.device !== device) {
    return {
      status: 403,
      body: { error: "device_mismatch", message: "That key was issued for a different Mac, so nothing was released." },
    };
  }

  const license = await store.licenseForKey(payload.email, payload.id, payload.device);
  if (!license) {
    return {
      status: 404,
      body: { error: "unknown_key", message: "This service has no record of that key. Nothing needed releasing." },
    };
  }

  await store.releaseSlot(license.id, device, now);
  log("device released", { key_id: payload.id, kind: payload.kind });

  return { status: 200, body: { released: true } };
}
