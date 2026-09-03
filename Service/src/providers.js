// The two payment providers, behind one shape.
//
// `docs/PHASE_8_DECISIONS.md` D2 settles this on availability rather than on
// economics: both are merchants of record, the fee difference is about a euro
// on a ninety-nine euro sale, and only one of them is confirmed to exist for
// this account. So both are written, `PAYMENT_PROVIDER` picks one, and the
// decision costs a variable rather than a rewrite.
//
// What is provider-specific is the signature and the field names. What is not
// is the effect: create or extend a license on an address, or mark one dead.
// Everything below turns the first into the second.
//
// The field paths are from each provider's documented payloads. **They are the
// one thing here that has not been run against a real event**, because that
// needs an account — so `parse` returns `null` rather than guessing when it
// cannot find an address, and a null is logged and answered with a 202 so the
// provider stops retrying while a human looks.

import { normalizeEmail } from "./email.js";

export const ANNUAL_SECONDS = 365 * 86400;

/// Constant-time comparison of two hex digests. A byte-at-a-time `===` on a
/// signature is a timing oracle, and this is the one place in the service where
/// that is not theoretical.
function equalHex(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i += 1) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
}

async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(signature)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/// Five minutes. A replayed webhook older than that is not a delivery attempt.
export const MAXIMUM_SIGNATURE_AGE = 300;

// MARK: - Paddle

export const paddle = {
  name: "paddle",

  /// `Paddle-Signature: ts=1700000000;h1=<hex>` over `${ts}:${body}`.
  async verify({ header, body, secret, now }) {
    if (!header || !secret) return false;
    const parts = Object.fromEntries(
      header.split(";").map((piece) => {
        const index = piece.indexOf("=");
        return [piece.slice(0, index).trim(), piece.slice(index + 1).trim()];
      }),
    );
    const timestamp = Number(parts.ts);
    if (!Number.isSafeInteger(timestamp) || Math.abs(now - timestamp) > MAXIMUM_SIGNATURE_AGE) return false;
    return equalHex(parts.h1 ?? "", await hmacHex(secret, `${timestamp}:${body}`));
  },

  parse(event, env, now) {
    const id = event?.event_id ?? event?.data?.id;
    const type = event?.event_type ?? "";
    const data = event?.data ?? {};

    if (type === "adjustment.created" && data.action === "refund") {
      return { id, effect: "refund", orderID: data.transaction_id ?? null };
    }
    if (type !== "transaction.completed" && type !== "transaction.paid") return { id, effect: "ignore" };

    const email = normalizeEmail(
      data.customer?.email ?? data.billing_details?.email ?? data.custom_data?.email ?? null,
    );
    const priceIDs = (data.items ?? data.details?.line_items ?? []).map(
      (item) => item.price?.id ?? item.price_id ?? null,
    );
    const kind = kindFor([data.custom_data?.price_id ?? null, ...priceIDs], env);
    if (!email || !kind) return null;

    return { id, effect: "purchase", email, kind, orderID: data.id ?? null, at: now };
  },
};

// MARK: - Stripe

export const stripe = {
  name: "stripe",

  /// `Stripe-Signature: t=1700000000,v1=<hex>` over `${t}.${body}`.
  async verify({ header, body, secret, now }) {
    if (!header || !secret) return false;
    const parts = {};
    for (const piece of header.split(",")) {
      const index = piece.indexOf("=");
      const name = piece.slice(0, index).trim();
      // A header may carry several v1 signatures during a secret rotation.
      (parts[name] ??= []).push(piece.slice(index + 1).trim());
    }
    const timestamp = Number(parts.t?.[0]);
    if (!Number.isSafeInteger(timestamp) || Math.abs(now - timestamp) > MAXIMUM_SIGNATURE_AGE) return false;

    const expected = await hmacHex(secret, `${timestamp}.${body}`);
    return (parts.v1 ?? []).some((candidate) => equalHex(candidate, expected));
  },

  parse(event, env, now) {
    const id = event?.id;
    const type = event?.type ?? "";
    const object = event?.data?.object ?? {};

    // `invoice.paid` and `invoice.payment_succeeded` both fire for the same
    // money and carry different event ids, so idempotency cannot save us from
    // acting on both — an annual would grow by two years for one payment.
    // Exactly one of them is acted on, and the other is refused here rather
    // than in a README nobody re-reads while clicking checkboxes.
    if (type === "invoice.payment_succeeded") return { id, effect: "ignore" };

    if (type === "invoice.paid") {
      // The first invoice of a subscription arrives alongside the checkout
      // session that created it. The session is what carries the buyer's
      // address, so the first one is left to the session and only the renewals
      // are read here.
      const reason = object.billing_reason ?? "";
      if (reason !== "subscription_cycle" && reason !== "subscription_update") {
        return { id, effect: "ignore" };
      }
      const email = normalizeEmail(object.customer_email ?? object.customer_details?.email ?? null);
      const kind = kindFor(identifiers(object), env);
      if (!email || !kind) return null;
      return { id, effect: "renewal", email, kind, orderID: object.subscription ?? object.id ?? null, at: now };
    }

    if (type === "charge.refunded" || type === "charge.dispute.created") {
      return {
        id,
        effect: "refund",
        orderID: object.payment_intent ?? object.charge ?? null,
        // A subscription's charge carries no payment intent this service ever
        // stored, so the address is the second way to find the licence. Both
        // are tried, in that order.
        email: normalizeEmail(object.billing_details?.email ?? object.receipt_email ?? null),
      };
    }

    if (type !== "checkout.session.completed") return { id, effect: "ignore" };

    const email = normalizeEmail(object.customer_details?.email ?? object.customer_email ?? null);
    const kind = kindFor(identifiers(object), env);
    if (!email || !kind) return null;

    // The payment intent first, because that is what a refund names. A
    // subscription checkout has none, so its own id is next, and the session id
    // is the fallback that always exists.
    return {
      id,
      effect: "purchase",
      email,
      kind,
      orderID: object.payment_intent ?? object.subscription ?? object.id ?? null,
      at: now,
    };
  },
};

/// Everything in an event that could say which of the two offers was bought.
///
/// Stripe does not expand line items on a webhook, so on a Payment Link
/// purchase the price id is simply not in the payload. What *is* there is the
/// link's own id — and we created both links, so we know which is which. All
/// three are collected and the first one that matches wins.
function identifiers(object) {
  const lineItems = object.line_items?.data ?? object.lines?.data ?? [];
  return [
    object.metadata?.price_id ?? null,
    object.payment_link ?? null,
    ...lineItems.map((item) => item.price?.id ?? item.plan?.id ?? null),
  ];
}

function kindFor(candidates, env) {
  const lifetime = [env.PRICE_LIFETIME, env.PAYMENT_LINK_LIFETIME].filter(Boolean);
  const annual = [env.PRICE_ANNUAL, env.PAYMENT_LINK_ANNUAL].filter(Boolean);
  for (const candidate of candidates) {
    if (!candidate) continue;
    if (lifetime.includes(candidate)) return "lifetime";
    if (annual.includes(candidate)) return "annual";
  }
  return null;
}

export function providerFor(env) {
  switch ((env.PAYMENT_PROVIDER ?? "").toLowerCase()) {
    case "paddle":
      return paddle;
    case "stripe":
      return stripe;
    default:
      return null;
  }
}

export function signatureHeader(provider, request) {
  return provider.name === "paddle"
    ? request.headers.get("Paddle-Signature")
    : request.headers.get("Stripe-Signature");
}
