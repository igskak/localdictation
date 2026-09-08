// POST /v1/events — the three facts about the funnel, and nothing else.
//
// `docs/PHASE_8_DECISIONS.md` D7 shipped the first release transmitting
// nothing. This route is the reversal, and it is deliberately the narrowest
// thing that answers the question it was opened for: how many people reach the
// wall at the fifth dictation, and how many get past it.
//
// The allowlists below are the second half of a boundary whose first half is in
// the app — `TelemetryEvent.transmitted`, an enum with no free-form field in
// it. Keeping both means a build that starts sending a fourth event is refused
// here rather than quietly collected, which is the only version of this promise
// that survives a mistake in a client nobody can update.

export const ALLOWED_EVENTS = new Set(["trial_started", "activation_requested", "paywall_shown"]);

/// Only `paywall_shown` has one, and only these four. Everything else in the
/// app's qualifier vocabulary belongs to events this route does not accept.
export const ALLOWED_QUALIFIERS = {
  paywall_shown: new Set(["activationRequired", "trialExpired", "licenseExpired", "updateRequired"]),
};

/// Ninety days. Long enough to compare a cohort against the fortnight after it,
/// short enough that this table is never the interesting thing in a breach.
/// `docs/PRIVACY.md` publishes this number.
export const RETENTION_SECONDS = 90 * 86400;

/// A random identifier, as `UUID().uuidString` writes it. Anything else is a
/// build that is not this app, or a caller inventing rows.
const INSTALL_PATTERN = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

/// Bounded, and narrow enough that neither field can carry a sentence.
const VERSION_PATTERN = /^[0-9A-Za-z.\-]{1,20}$/;

/// Wide enough that one Mac's whole fortnight fits, narrow enough that a script
/// cannot make this table the size of the licence table. Per install and per
/// address block, the two the activation route already counts.
export const RATE_LIMITS = {
  install: { limit: 60, window: 3600 },
  address: { limit: 600, window: 3600 },
};

/// Answers `202` to everything it accepts and says nothing else.
///
/// The app does not read the reply — see `HTTPProductTelemetryService` — so the
/// status codes here exist for whoever is looking at this service, not for a
/// user who is about to be shown a sentence. Which is also why a refusal
/// carries no `message`: there is no one to read it.
export async function record({ body, store, now, clientIP, log }) {
  if ((await store.bump(`ip:${clientIP}`, now, RATE_LIMITS.address.window)) > RATE_LIMITS.address.limit) {
    return { status: 429, body: { error: "rate_limited" } };
  }

  const installID = typeof body?.install_id === "string" ? body.install_id.trim() : "";
  if (!INSTALL_PATTERN.test(installID)) return { status: 400, body: { error: "invalid_install_id" } };

  if ((await store.bump(`events:${installID}`, now, RATE_LIMITS.install.window)) > RATE_LIMITS.install.limit) {
    return { status: 429, body: { error: "rate_limited" } };
  }

  const event = typeof body?.event === "string" ? body.event : "";
  if (!ALLOWED_EVENTS.has(event)) {
    // Worth a line in the log rather than a silent drop: an event name arriving
    // here that this service does not know is either a client that got ahead of
    // this file or somebody probing, and the two look different in volume.
    log("unlisted event refused", { event: event.slice(0, 40) });
    return { status: 400, body: { error: "unknown_event" } };
  }

  const qualifier = body?.qualifier === undefined || body?.qualifier === null ? null : body.qualifier;
  if (qualifier !== null) {
    const allowed = ALLOWED_QUALIFIERS[event];
    if (typeof qualifier !== "string" || !allowed?.has(qualifier)) {
      return { status: 400, body: { error: "unknown_qualifier" } };
    }
  }

  const appVersion = typeof body?.app_version === "string" ? body.app_version : "";
  const systemVersion = typeof body?.system_version === "string" ? body.system_version : "";
  if (!VERSION_PATTERN.test(appVersion) || !VERSION_PATTERN.test(systemVersion)) {
    return { status: 400, body: { error: "invalid_version" } };
  }

  await store.recordEvent({ installID, event, qualifier, appVersion, systemVersion, at: now });

  return { status: 202, body: {} };
}
