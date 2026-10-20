// POST /v1/subscriptions/cancel — the website's cancellation button.
//
// §312k BGB wants a button that ends a consumer contract made online, reachable
// without signing in, answered at once with a confirmation in text form. So this
// route takes an address and does it: the subscription behind every live annual
// licence on that address stops renewing, and the paid time is honoured.
//
// There is deliberately no second step. A cancellation anybody can ask for
// knowing an address is a nuisance at worst — the paid period is untouched, the
// owner is mailed, and "Manage subscription" in the app resumes it — and a
// confirmation link in front of the button is what the law says the button
// must not have.
//
// The answer never says whether the address held anything, so the route cannot
// be used to find out who is a customer.

import { normalizeEmail } from "./email.js";
import { cancellationMail } from "./mailer.js";
import { EVENTS } from "./analytics.js";

export const CANCEL_LIMITS = {
  email: { limit: 5, window: 3600 },
  address: { limit: 30, window: 3600 },
};

const NEUTRAL = {
  received: true,
  message: "If a subscription runs under this address, it is cancelled and the confirmation is on its way to it.",
};

export async function cancelSubscription({ body, store, now, clientIP, billing, mailer, log, analytics = { capture() {} } }) {
  if ((await store.bump(`cancel-ip:${clientIP}`, now, CANCEL_LIMITS.address.window)) > CANCEL_LIMITS.address.limit) {
    return { status: 429, body: { error: "rate_limited" }, headers: { "Retry-After": "60" } };
  }

  const email = normalizeEmail(body?.email);
  if (!email) return { status: 400, body: { error: "invalid_email" } };

  if ((await store.bump(`cancel-email:${email}`, now, CANCEL_LIMITS.email.window)) > CANCEL_LIMITS.email.limit) {
    return { status: 429, body: { error: "rate_limited" }, headers: { "Retry-After": "60" } };
  }

  let endsAt = null;
  let cancelled = false;

  for (const license of await store.liveAnnualLicenses(email)) {
    for (const subscription of await store.subscriptionIDs(license.id)) {
      try {
        if (await billing.cancelAtPeriodEnd(subscription)) {
          cancelled = true;
          endsAt = Math.max(endsAt ?? 0, license.expires_at ?? now);
          analytics.capture(EVENTS.subscription_cancel_requested, license.id, { kind: license.kind }, now);
        }
      } catch (error) {
        log("cancellation failed", { license: license.id, reason: String(error?.name ?? "error") });
      }
    }
  }

  if (cancelled) {
    log("subscription cancelled at period end");
    try {
      await mailer.send({ to: email, ...cancellationMail({ endsAt, at: now }) });
    } catch (error) {
      log("cancellation mail failed", { reason: String(error?.name ?? "error") });
    }
  }

  return { status: 200, body: NEUTRAL };
}
