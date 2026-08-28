// A throwaway signing identity.
//
// The production one lives in a Workers secret and in one file on one laptop.
// Every test here makes its own, in the same form: base64 of the raw 32-byte
// Ed25519 seed, which is what `CryptoKit`'s `rawRepresentation` writes and what
// `Tools/licensekit.swift` stores.

import { generateKeyPairSync, createPublicKey, createPrivateKey } from "node:crypto";

/// The last 32 bytes of a PKCS#8 Ed25519 private key are the seed, and the last
/// 32 of an SPKI public key are the point. Both prefixes are fixed-length DER.
export function makeKeypair() {
  const { privateKey } = generateKeyPairSync("ed25519");
  return describe(privateKey);
}

export function keypairFromSeed(seed) {
  const pkcs8 = Buffer.concat([
    Buffer.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]),
    Buffer.from(seed),
  ]);
  return describe(createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" }));
}

function describe(privateKey) {
  const pkcs8 = privateKey.export({ format: "der", type: "pkcs8" });
  const spki = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  return {
    privateBase64: Buffer.from(pkcs8.subarray(pkcs8.length - 32)).toString("base64"),
    publicBase64: Buffer.from(spki.subarray(spki.length - 32)).toString("base64"),
  };
}
