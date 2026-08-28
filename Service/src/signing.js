// The signing identity, and the only place a private key is touched.
//
// `Tools/licensekit.swift` writes the private key as base64 of the raw 32-byte
// Ed25519 seed, which is what `CryptoKit`'s `rawRepresentation` is. WebCrypto
// will not import that form directly — it wants PKCS#8 — so the fixed 16-byte
// DER header below is prepended to it. That is the whole of the conversion,
// and it means the secret this service holds is byte for byte the file that
// has been issuing keys by hand: moving issuing here does not invalidate a
// single key already sold.

const PKCS8_ED25519_HEADER = new Uint8Array([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
  0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
]);

import { base64ToBytes } from "./base64.js";

export const ALGORITHM = "Ed25519";

export function pkcs8FromRawSeed(seed) {
  if (seed.length !== 32) throw new Error(`an Ed25519 seed is 32 bytes, not ${seed.length}`);
  const out = new Uint8Array(PKCS8_ED25519_HEADER.length + 32);
  out.set(PKCS8_ED25519_HEADER, 0);
  out.set(seed, PKCS8_ED25519_HEADER.length);
  return out;
}

/// The private half, from the base64 in `LICENSE_SIGNING_KEY`.
export async function importSigningKey(base64Seed) {
  const seed = base64ToBytes(base64Seed.trim());
  return crypto.subtle.importKey("pkcs8", pkcs8FromRawSeed(seed), { name: ALGORITHM }, false, ["sign"]);
}

/// The public half, from the base64 the app carries in `LicenseAuthority`.
export async function importVerifyingKey(base64Raw) {
  const raw = base64ToBytes(base64Raw.trim());
  return crypto.subtle.importKey("raw", raw, { name: ALGORITHM }, false, ["verify"]);
}

export async function sign(key, bytes) {
  return new Uint8Array(await crypto.subtle.sign({ name: ALGORITHM }, key, bytes));
}

export async function verify(key, signature, bytes) {
  return crypto.subtle.verify({ name: ALGORITHM }, key, signature, bytes);
}

/// Does the secret we are signing with match the public key the shipped app
/// checks against?
///
/// The failure this catches is the expensive one and the silent one: a wrong
/// secret issues keys that verify nowhere, the service looks healthy, and the
/// first person to notice is a customer whose app refuses the key it was just
/// mailed. Signing a probe and checking it against the app's own authority is
/// the only way to ask the question without holding both halves.
export async function signingKeyMatchesAuthority(signingKey, publicKeyBase64) {
  try {
    const probe = new TextEncoder().encode("localdictation.authority.probe");
    const signature = await sign(signingKey, probe);
    return await verify(await importVerifyingKey(publicKeyBase64), signature, probe);
  } catch {
    return false;
  }
}
