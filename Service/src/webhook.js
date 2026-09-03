// POST /v1/purchases/webhook — where money becomes an entitlement.
//
// It creates or extends a license on **the address the buyer used**, and mails
// them one instruction: open the app, Settings, License, type that address,
// press Send my key. That sentence is what the "a key names a Mac" decision
// costs, and it belongs in the purchase mail rather than being discovered.
//
// A key cannot be issued here. A browser does not know which Mac it is buying
// for, and the payload of a key names one.

import { ANNUAL_SECONDS } from "./providers.js";
import { purchaseMail, renewalMail } from "./mailer.js";

export async function handleEvent({ event, provider, env, store, now, mailer, log, uuid = () => crypto.randomUUID() }) {
  const parsed = provider.parse(event, env, now);

  // Not a shape this service recognised. Answered 202 rather than 400 so the
  // provider stops redelivering while somebody looks at the log line — a
  // webhook retried every hour for a week is how a small mapping mistake
  // becomes an outage.
  if (parsed === null) {
    log("event not understood", { provider: provider.name, type: event?.type ?? event?.event_type ?? "unknown" });
    return { status: 202, body: { received: true, applied: false } };
  }

  if (!parsed.id) {
    return { status: 400, body: { error: "missing_event_id" } };
  }

  // Every provider re-delivers, and a second delivery must not create a second
  // license. Claimed before anything is written.
  if (!(await store.claimEvent(parsed.id, now))) {
    log("event already applied", { provider: provider.name });
    return { status: 200, body: { received: true, applied: false } };
  }

  if (parsed.effect === "ignore") {
    return { status: 200, body: { received: true, applied: false } };
  }

  if (parsed.effect !== "refund" && parsed.effect !== "purchase" && parsed.effect !== "renewal") {
    log("effect not understood", { effect: String(parsed.effect) });
    return { status: 202, body: { received: true, applied: false } };
  }

  if (parsed.effect === "refund") {
    // Dead for *future* issuance only. A key already on somebody's Mac keeps
    // working: Phase 6 chose an offline check with its eyes open, and a
    // revocation call in the app would trade the product's central promise for
    // a rounding error in fraud.
    //
    // Two ways to find the licence, in order. A one-off purchase is found by
    // the payment intent the refund names; a subscription's charge names a
    // payment intent this service never stored, so the address is the fallback.
    const license =
      (parsed.orderID ? await store.licenseByOrder(parsed.orderID) : null) ??
      (parsed.email ? await store.newestPaidLicense(parsed.email) : null);
    if (license) {
      await store.killLicense(license.id);
      log("license marked dead", { license: license.id });
      return { status: 200, body: { received: true, applied: true } };
    }
    log("refund for an order this service does not have", { provider: provider.name });
    return { status: 200, body: { received: true, applied: false } };
  }

  // A renewal and a purchase do the same thing to the row: the licence on that
  // address gets a later date, or loses its date entirely. What differs is the
  // sentence the person is sent, because a renewal is not a first step.
  const existing =
    (await store.strongestLicense(parsed.email, now)) ??
    (parsed.effect === "renewal" ? await store.newestPaidLicense(parsed.email) : null);
  let license;

  if (existing && existing.kind !== "trial") {
    // A renewal, or a lifetime bought on top of an annual. Once either side is
    // lifetime the license is lifetime and loses its date; otherwise the annual
    // extends from whichever is later, the current expiry or now, so renewing
    // early is never a punishment.
    const lifetime = parsed.kind === "lifetime" || existing.kind === "lifetime";
    license = await store.extendLicense({
      id: existing.id,
      kind: lifetime ? "lifetime" : "annual",
      expiresAt: lifetime ? null : Math.max(existing.expires_at ?? now, now) + ANNUAL_SECONDS,
      providerOrderID: parsed.orderID,
    });
  } else {
    // A trial on the address is left alone rather than upgraded: it is a
    // separate row with its own history, and `POST /v1/activate` already
    // prefers the stronger one.
    license = await store.createLicense({
      id: uuid(),
      email: parsed.email,
      kind: parsed.kind,
      issuedAt: now,
      expiresAt: parsed.kind === "lifetime" ? null : now + ANNUAL_SECONDS,
      providerOrderID: parsed.orderID,
    });
  }

  log(parsed.effect === "renewal" ? "license renewed" : "license from a purchase", {
    license: license.id,
    kind: license.kind,
  });

  try {
    const mail =
      parsed.effect === "renewal"
        ? renewalMail({ expiresAt: license.expires_at })
        : purchaseMail({ kind: license.kind, expiresAt: license.expires_at });
    await mailer.send({ to: parsed.email, ...mail });
  } catch (error) {
    // The entitlement is recorded, which is the part that must not be lost. The
    // buyer can still activate from inside the app without ever reading a mail.
    log("purchase mail failed", { license: license.id, reason: String(error?.name ?? "error") });
  }

  return { status: 200, body: { received: true, applied: true } };
}
