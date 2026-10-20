// How long a subscription key lives, and when it is replaced.
//
// An annual licence is paid for a year, but the key that goes on a Mac is not
// dated a year ahead. It lives thirty days and the app swaps it for a fresh one
// in its last week, silently, by asking `POST /v1/activate` again. That is the
// whole revocation story for a subscription: a refund or a cancellation stops
// the *next* key, and the one already on the Mac runs out within a month. An
// offline check cannot be recalled any faster, and a daily check in the app
// would be a different product.
//
// **These numbers and `LicenseRefreshPolicy` in the app are one decision in two
// languages**, the same way `TRIAL_SECONDS` is: this side puts the date in the
// key, the app side decides when to ask again.

/// The ungated three days are the app's; this is what a payer's key covers
/// after the €4.99 introductory payment, counted from the payment.
export const INTRO_SECONDS = 14 * 86400;

export const ANNUAL_SECONDS = 365 * 86400;

/// What one key covers.
export const KEY_SECONDS = 30 * 86400;

/// How long after the paid-through date a key may still be issued, so a card
/// that Stripe is still retrying does not lock somebody out on the day it
/// declines.
export const GRACE_SECONDS = 7 * 86400;

/// How close to its own end a key has to be before a new one is issued. Asking
/// earlier returns the same key, byte for byte.
export const REFRESH_WINDOW_SECONDS = 7 * 86400;

/// The date a key issued at `now` for this licence should carry, in seconds, or
/// `null` for a key that does not expire.
///
/// Trials keep their own date, lifetimes have none, and an annual licence gets
/// the shorter of a month from now and a week past what was paid for.
export function keyExpiry(license, now) {
  if (license.kind === "lifetime") return null;
  if (license.kind !== "annual") return license.expires_at ?? null;
  return Math.min(now + KEY_SECONDS, (license.expires_at ?? now) + GRACE_SECONDS);
}

/// Whether the key a slot already holds should be replaced by a fresh one.
///
/// Only a key that is in its last week, or past its end, and only when the
/// licence would actually give it a later date. A licence that was not renewed
/// keeps returning the key it has, which then expires on its own date.
export function shouldReissue(slotExpiresAt, license, now) {
  if (license.kind !== "annual") return (slotExpiresAt ?? null) !== (license.expires_at ?? null);
  if (slotExpiresAt == null) return true;
  if (slotExpiresAt - now > REFRESH_WINDOW_SECONDS) return false;
  return keyExpiry(license, now) > slotExpiresAt;
}
