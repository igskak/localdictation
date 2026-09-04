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
    // Found only by an identifier this service recorded when the licence was
    // bought. Not by the customer's address: one payment account can sell more
    // than one product to the same person, and a refund for the other one must
    // not kill this one's licence.
    const license =
      (await store.licenseByRef(parsed.lookup ?? [])) ??
      (parsed.orderID ? await store.licenseByOrder(parsed.orderID) : null);
    if (license) {
      await store.killLicense(license.id);
      log("license marked dead", { license: license.id });
      return { status: 200, body: { received: true, applied: true } };
    }
    // Almost always another product on the same account, which is why this is
    // an acknowledgement and not an error.
    log("refund for nothing this service issued", { provider: provider.name });
    return { status: 200, body: { received: true, applied: false } };
  }

  // A renewal is found by the subscription it renews, and if that subscription
  // belongs to another product on the same account it is found by nothing and
  // ignored. A purchase is found by the address, because it is the event that
  // creates the licence and there is nothing recorded yet to match.
  if (parsed.effect === "renewal") {
    const renewed = await store.licenseByRef(parsed.lookup ?? []);
    if (!renewed) {
      log("renewal for a subscription this service does not have", { provider: provider.name });
      return { status: 200, body: { received: true, applied: false } };
    }
    const expiresAt = Math.max(renewed.expires_at ?? now, now) + ANNUAL_SECONDS;
    const license = await store.extendLicense({
      id: renewed.id,
      kind: renewed.kind === "lifetime" ? "lifetime" : "annual",
      expiresAt: renewed.kind === "lifetime" ? null : expiresAt,
      providerOrderID: renewed.provider_order_id,
    });
    await store.recordRefs(license.id, parsed.refs ?? [], now);
    log("license renewed", { license: license.id, kind: license.kind });

    // The address comes off the licence rather than out of the event: it is the
    // one this service issued keys to, whatever the invoice happens to carry.
    try {
      await mailer.send({ to: license.email, ...renewalMail({ expiresAt: license.expires_at }) });
    } catch (error) {
      log("renewal mail failed", { license: license.id, reason: String(error?.name ?? "error") });
    }

    return { status: 200, body: { received: true, applied: true } };
  }

  const existing = await store.strongestLicense(parsed.email, now);
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

  // Every identifier this purchase carries, so a refund or a renewal a year
  // from now can be matched to it without guessing.
  await store.recordRefs(license.id, parsed.refs ?? [], now);

  log("license from a purchase", { license: license.id, kind: license.kind });

  try {
    await mailer.send({ to: parsed.email, ...purchaseMail({ kind: license.kind, expiresAt: license.expires_at }) });
  } catch (error) {
    // The entitlement is recorded, which is the part that must not be lost. The
    // buyer can still activate from inside the app without ever reading a mail.
    log("purchase mail failed", { license: license.id, reason: String(error?.name ?? "error") });
  }

  return { status: 200, body: { received: true, applied: true } };
}
