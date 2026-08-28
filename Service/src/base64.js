// Base64 and base64url, on the bytes rather than on a string.
//
// `btoa` and `atob` exist in Workers and in Node, and `Buffer` exists only in
// one of them. Everything here is written against the pair that works in both,
// because the module that signs a license key is the one place where "it
// worked in the test runner" and "it worked in production" have to be the same
// sentence.

export function bytesToBase64(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function base64ToBytes(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/// base64url, unpadded — the form a key survives being pasted into an email in.
export function bytesToBase64URL(bytes) {
  return bytesToBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function base64URLToBytes(text) {
  let value = text.replaceAll("-", "+").replaceAll("_", "/");
  while (value.length % 4 !== 0) value += "=";
  return base64ToBytes(value);
}
