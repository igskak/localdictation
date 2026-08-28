// The license token, byte for byte.
//
// `docs/PHASE_8.md` freezes this, and `LicenseKey.verify` in the app checks the
// signature over **the payload bytes as they appear in the token** — so what
// this module emits and what it signs must be the same array of bytes, and a
// re-serialization anywhere between the two is a key that verifies nowhere.
//
//   LD1.<base64url(payload JSON)>.<base64url(Ed25519 signature)>
//
// The payload is compact JSON, keys in lexicographic order, whole seconds:
//
//   {"device":"...","email":"...","expires":1731628800,"id":"...","issued":1700092800,"kind":"trial"}
//
// `expires` is omitted entirely for a lifetime key rather than set to null,
// because Swift's encoder omits a nil optional and the app refuses a lifetime
// key that carries a date.

import { bytesToBase64URL, base64URLToBytes } from "./base64.js";
import { sign, verify } from "./signing.js";

export const TOKEN_PREFIX = "LD1";
export const KINDS = ["trial", "annual", "lifetime"];
export const DEVICE_PATTERN = /^[0-9a-f]{32}$/;

/// The exact bytes that get signed.
///
/// The keys are inserted in lexicographic order and handed to `JSON.stringify`,
/// which preserves insertion order and — the reason it is used rather than
/// string concatenation — escapes an address that contains something JSON has
/// an opinion about.
export function canonicalPayloadBytes(fields) {
  const { device, email, expires, id, issued, kind } = fields;

  if (!DEVICE_PATTERN.test(device ?? "")) throw new Error("device must be 32 lowercase hex characters");
  if (typeof email !== "string" || email.length === 0) throw new Error("email is required");
  if (typeof id !== "string" || id.length === 0) throw new Error("id is required");
  if (!KINDS.includes(kind)) throw new Error(`kind must be one of ${KINDS.join(", ")}`);
  if (!Number.isSafeInteger(issued)) throw new Error("issued must be whole seconds since the epoch");

  const isDated = kind !== "lifetime";
  if (isDated) {
    if (!Number.isSafeInteger(expires)) throw new Error("a dated key needs whole-second expires");
    if (expires <= issued) throw new Error("expires must be later than issued");
  } else if (expires !== undefined && expires !== null) {
    throw new Error("a lifetime key carries no expiry");
  }

  const payload = {};
  payload.device = device;
  payload.email = email;
  if (isDated) payload.expires = expires;
  payload.id = id;
  payload.issued = issued;
  payload.kind = kind;

  return new TextEncoder().encode(JSON.stringify(payload));
}

/// Signs a key. Ed25519 is deterministic, so the same fields always produce the
/// same token — which is what makes re-issuing a device's key idempotent
/// without this service ever having to store the key it issued.
export async function issueToken(fields, signingKey) {
  const payload = canonicalPayloadBytes(fields);
  const signature = await sign(signingKey, payload);
  return `${TOKEN_PREFIX}.${bytesToBase64URL(payload)}.${bytesToBase64URL(signature)}`;
}

/// Splits a token without believing anything in it.
export function decodeToken(token) {
  if (typeof token !== "string") return null;
  const parts = token.trim().split(".");
  if (parts.length !== 3) return null;
  const [prefix, encodedPayload, encodedSignature] = parts;
  if (prefix !== TOKEN_PREFIX || !encodedPayload || !encodedSignature) return null;

  let payloadBytes;
  let signature;
  try {
    payloadBytes = base64URLToBytes(encodedPayload);
    signature = base64URLToBytes(encodedSignature);
  } catch {
    return null;
  }

  let payload;
  try {
    payload = JSON.parse(new TextDecoder().decode(payloadBytes));
  } catch {
    return null;
  }
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) return null;

  return { payload, payloadBytes, signature };
}

/// Verifies a token the way the app does: the signature first, over the bytes
/// as they arrived, and only then is anything in the payload believed.
export async function verifyToken(token, verifyingKey) {
  const decoded = decodeToken(token);
  if (!decoded) return null;
  if (!(await verify(verifyingKey, decoded.signature, decoded.payloadBytes))) return null;

  const { payload } = decoded;
  if (!KINDS.includes(payload.kind)) return null;
  if (!DEVICE_PATTERN.test(payload.device ?? "")) return null;
  if (typeof payload.id !== "string" || typeof payload.email !== "string") return null;
  if (!Number.isSafeInteger(payload.issued)) return null;

  const isDated = payload.kind !== "lifetime";
  if (isDated) {
    if (!Number.isSafeInteger(payload.expires) || payload.expires <= payload.issued) return null;
  } else if (payload.expires !== undefined) {
    return null;
  }

  return payload;
}
