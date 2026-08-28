// POST /v1/activate — the one call the app makes, and everything it can answer.
//
// There is one endpoint because what a person owns is the service's business,
// not the app's: an address with nothing on it gets a trial, an address that
// bought something gets a key for what it bought, and the app cannot tell the
// difference and does not have to.
//
// The steps are `docs/PHASE_8.md`'s, in its order.

import { normalizeEmail } from "./email.js";
import { DEVICE_PATTERN, issueToken } from "./token.js";
import { activationMail } from "./mailer.js";

export const TRIAL_SECONDS = 14 * 86400;
export const DEVICE_LIMIT = 2;

/// Generous per address and per Mac — a person pressing a button that seems not
/// to have worked will press it again — and wide enough per address block that
/// an office behind one NAT is not a suspect.
export const RATE_LIMITS = {
  email: { limit: 10, window: 3600 },
  device: { limit: 10, window: 3600 },
  address: { limit: 120, window: 3600 },
};

export async function activate({ body, store, now, clientIP, signingKey, mailer, log, uuid = () => crypto.randomUUID() }) {
  // Counted before anything is validated, so a flood of malformed bodies costs
  // the sender its budget rather than costing this service a database.
  if ((await store.bump(`ip:${clientIP}`, now, RATE_LIMITS.address.window)) > RATE_LIMITS.address.limit) {
    return tooMany();
  }

  const device = typeof body?.device === "string" ? body.device.trim() : "";
  if (!DEVICE_PATTERN.test(device)) {
    return {
      status: 400,
      body: {
        error: "invalid_device",
        message: "This build sent an identifier this service does not recognise. Update LocalDictation and try again.",
      },
    };
  }

  const email = normalizeEmail(body?.email);
  if (!email) return { status: 400, body: { error: "invalid_email" } };

  if (
    (await store.bump(`email:${email}`, now, RATE_LIMITS.email.window)) > RATE_LIMITS.email.limit ||
    (await store.bump(`device:${device}`, now, RATE_LIMITS.device.window)) > RATE_LIMITS.device.limit
  ) {
    return tooMany();
  }

  let license = await store.strongestLicense(email, now);

  if (!license) {
    // A second trial is refused rather than quietly granted, and the refusal
    // names the way forward — a message the app shows verbatim.
    if ((await store.hasHadTrial(email)) || (await store.deviceHasHadTrial(device))) {
      return {
        status: 422,
        body: {
          error: "trial_used",
          message:
            "This address or this Mac has already had the free trial. A licence keeps it dictating: EUR 99 once, or EUR 49 a year, both covering two Macs.",
        },
      };
    }

    license = await store.createLicense({
      id: uuid(),
      email,
      kind: "trial",
      issuedAt: now,
      // The app measures its own fourteen days from the first dictation and
      // this service does not know that date, so someone who activates late
      // gets slightly more than fourteen days of dictation. That is the right
      // way round for the error to fall.
      expiresAt: now + TRIAL_SECONDS,
      device,
    });
    log("license created", { license: license.id, kind: license.kind });
  }

  let slot = await store.slot(license.id, device);
  let isNewSlot = false;

  if (slot) {
    // A renewal moved the license's date after this key was issued. Same slot,
    // same key id, new expiry — so the user is not paying a device slot for
    // their own renewal.
    if ((slot.expires_at ?? null) !== (license.expires_at ?? null)) {
      slot = await store.reissueSlot({ licenseID: license.id, device, expiresAt: license.expires_at });
    }
  } else {
    if ((await store.liveSlotCount(license.id)) >= DEVICE_LIMIT) {
      return { status: 409, body: { error: "device_limit" } };
    }
    slot = await store.claimSlot({
      licenseID: license.id,
      device,
      keyID: uuid(),
      issuedAt: now,
      expiresAt: license.expires_at,
    });
    isNewSlot = true;
  }

  // Deterministic: the same five fields always produce the same token, so the
  // second press of the button returns the identical key without this service
  // ever having stored one.
  const key = await issueToken(
    {
      device,
      email,
      expires: license.kind === "lifetime" ? undefined : slot.expires_at,
      id: slot.key_id,
      issued: slot.issued_at,
      kind: license.kind,
    },
    signingKey,
  );

  if (slot.mailed_at == null) {
    const mail = activationMail({ key, kind: license.kind, expiresAt: slot.expires_at });
    let delivered = false;
    try {
      delivered = await mailer.send({ to: email, ...mail });
    } catch (error) {
      log("mail failed", { license: license.id, reason: String(error?.name ?? "error") });
    }
    // Only on success: an undelivered key is worth another attempt at the next
    // press, and the reply the user is holding has already unlocked their app.
    if (delivered) await store.markSlotMailed(license.id, device, now);
  }

  // The address never appears in a log line. The key id is what a support
  // conversation is conducted in.
  log("key issued", { key_id: slot.key_id, kind: license.kind, slot: isNewSlot ? "new" : "reissued" });

  return { status: 200, body: { key } };
}

function tooMany() {
  return {
    status: 429,
    body: { error: "rate_limited" },
    headers: { "Retry-After": "60" },
  };
}
