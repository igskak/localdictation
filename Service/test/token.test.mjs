// The frozen bytes.
//
// `docs/PHASE_8.md` writes the payload out character by character, and
// `LicenseKey.verify` checks a signature over exactly those bytes. Everything
// here is an assertion about a byte, not about an intention.

import test from "node:test";
import assert from "node:assert/strict";

import { canonicalPayloadBytes, issueToken, decodeToken, verifyToken, DEVICE_PATTERN } from "../src/token.js";
import { importSigningKey, importVerifyingKey } from "../src/signing.js";
import { makeKeypair } from "./support/keys.mjs";

const device = "0123456789abcdef0123456789abcdef";
const email = "owner@example.com";
const id = "0f4c3f5a-1f1e-4b0b-9b8a-8f1f3d2c1b0a";
const issued = 1700092800;
const expires = 1731628800;

const text = (bytes) => new TextDecoder().decode(bytes);

test("the payload is compact, lexicographic, and whole seconds", () => {
  assert.equal(
    text(canonicalPayloadBytes({ device, email, expires, id, issued, kind: "trial" })),
    `{"device":"${device}","email":"${email}","expires":${expires},"id":"${id}","issued":${issued},"kind":"trial"}`,
  );
});

test("a lifetime key omits expires entirely rather than carrying null", () => {
  const payload = text(canonicalPayloadBytes({ device, email, id, issued, kind: "lifetime" }));
  assert.equal(payload, `{"device":"${device}","email":"${email}","id":"${id}","issued":${issued},"kind":"lifetime"}`);
  assert.ok(!payload.includes("expires"));
});

test("a lifetime key with a date is refused, and so is a dated key without one", () => {
  assert.throws(() => canonicalPayloadBytes({ device, email, expires, id, issued, kind: "lifetime" }));
  assert.throws(() => canonicalPayloadBytes({ device, email, id, issued, kind: "annual" }));
});

test("fractional seconds are refused: they encode differently in Swift and in JavaScript", () => {
  assert.throws(() => canonicalPayloadBytes({ device, email, expires, id, issued: issued + 0.5, kind: "trial" }));
  assert.throws(() => canonicalPayloadBytes({ device, email, expires: expires + 0.25, id, issued, kind: "trial" }));
});

test("expires must be later than issued", () => {
  assert.throws(() => canonicalPayloadBytes({ device, email, expires: issued, id, issued, kind: "trial" }));
});

test("a device is 32 lowercase hex characters", () => {
  assert.ok(DEVICE_PATTERN.test(device));
  assert.ok(!DEVICE_PATTERN.test(device.toUpperCase()));
  assert.ok(!DEVICE_PATTERN.test(device.slice(1)));
  assert.throws(() => canonicalPayloadBytes({ device: "nope", email, expires, id, issued, kind: "trial" }));
});

test("an address JSON has an opinion about is escaped rather than concatenated", () => {
  const awkward = 'a"b\\c@example.com';
  const payload = text(canonicalPayloadBytes({ device, email: awkward, expires, id, issued, kind: "trial" }));
  assert.equal(JSON.parse(payload).email, awkward);
});

test("the same fields always produce the same token, so re-issuing is free", async () => {
  const { privateBase64 } = makeKeypair();
  const key = await importSigningKey(privateBase64);
  const first = await issueToken({ device, email, expires, id, issued, kind: "trial" }, key);
  const second = await issueToken({ device, email, expires, id, issued, kind: "trial" }, key);
  assert.equal(first, second);
});

test("a token is three base64url parts behind LD1", async () => {
  const { privateBase64 } = makeKeypair();
  const token = await issueToken({ device, email, expires, id, issued, kind: "trial" }, await importSigningKey(privateBase64));
  assert.match(token, /^LD1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.ok(!token.includes("="));
});

test("a token verifies, and an edited one does not", async () => {
  const { privateBase64, publicBase64 } = makeKeypair();
  const signing = await importSigningKey(privateBase64);
  const verifying = await importVerifyingKey(publicBase64);

  const token = await issueToken({ device, email, expires, id, issued, kind: "annual" }, signing);
  const payload = await verifyToken(token, verifying);
  assert.equal(payload.kind, "annual");
  assert.equal(payload.device, device);
  assert.equal(payload.expires, expires);

  const parts = token.split(".");
  const edited = decodeToken(token);
  const tampered = { ...edited.payload, kind: "lifetime" };
  const forged = ["LD1", Buffer.from(JSON.stringify(tampered)).toString("base64url"), parts[2]].join(".");
  assert.equal(await verifyToken(forged, verifying), null);
});

test("a key from another authority verifies against nothing", async () => {
  const mine = makeKeypair();
  const theirs = makeKeypair();
  const token = await issueToken({ device, email, expires, id, issued, kind: "trial" }, await importSigningKey(theirs.privateBase64));
  assert.equal(await verifyToken(token, await importVerifyingKey(mine.publicBase64)), null);
});

test("something that is not a token is not read as one", async () => {
  const { publicBase64 } = makeKeypair();
  const verifying = await importVerifyingKey(publicBase64);
  for (const value of ["", "LD1", "LD1..", "LD2.a.b", "hello", "LD1.$$$.$$$", null, 7]) {
    assert.equal(await verifyToken(value, verifying), null, `read ${JSON.stringify(value)} as a token`);
  }
});
