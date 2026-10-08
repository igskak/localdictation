// What this service tells PostHog, and the list that stops it telling more.
//
// Four facts about the business, each the moment it becomes true: a trial was
// issued, a licence was bought, a licence renewed, a licence was refunded. They
// sit on the same dashboard as the website's visits and downloads, so the whole
// path from an ad to money is one screen — as counts over time, not as people.
//
// And the nine events the app itself sends to `/v1/events`, passed on exactly as
// they were accepted, so that the stretch between a download and a first
// dictation is on that same screen. They carry the install's own random id,
// which is the only way to count installs rather than events, and the three
// fields the app already sent; nothing is added and nothing is joined to a
// licence, an address or a device.
//
// The boundary is a list, the same way the app's product events are an enum:
//
// - **No address, no device, no IP.** The distinct id is the licence's own
//   random id, which PostHog has no way to connect to anyone. `$geoip_disable`
//   is set because the only IP PostHog would see is Cloudflare's, and a city
//   resolved from it would be a confident lie on a map.
// - **No person profiles.** `$process_person_profile: false` makes every event
//   anonymous in PostHog's own terms, so nothing accumulates against the id.
// - **Only allowlisted properties leave.** `ALLOWED_PROPERTIES` is checked on
//   every call and anything else is dropped, so a caller that passes the
//   licence row by mistake sends `kind` and nothing more.
//
// And it can never cost a customer anything. Sending happens behind the reply
// through `ctx.waitUntil`, a failure is one log line, and a deployment with no
// `POSTHOG_KEY` sends nothing at all.

import { ALLOWED_EVENTS as FUNNEL_EVENTS } from "./events.js";

export const EVENTS = {
  trial_issued: "trial_issued",
  license_purchased: "license_purchased",
  license_renewed: "license_renewed",
  license_refunded: "license_refunded",
};

/// `revenue` is in major units and signed: a refund is negative, so summing the
/// property over every event gives net takings. `currency` is upper-case ISO.
/// Both are gross — what the buyer paid, VAT included, before the payment
/// provider's fee.
///
/// `promo` is the label of a promotion code we issued, taken from the
/// `PROMO_CODES` list in `wrangler.toml`, or the word `other` for a discounted
/// sale whose code is not on that list. It is never what the buyer typed and
/// never a Stripe id: a partner's code is not personal data, an arbitrary
/// string would not be known to be.
///
/// `qualifier`, `app_version` and `system_version` are the app's own fields, each
/// from a fixed vocabulary or a bounded pattern that `events.js` has already
/// enforced by the time an event gets here.
export const ALLOWED_PROPERTIES = [
  "kind", "revenue", "currency", "provider", "upgrade", "promo", "qualifier", "app_version", "system_version",
];

const DEFAULT_HOST = "https://eu.i.posthog.com";

export function createAnalytics(env, { log = () => {}, ctx = null, fetcher = fetch } = {}) {
  const key = env.POSTHOG_KEY;
  if (!key) return { enabled: false, capture() {} };

  // EU only. The privacy policy says these events are processed in the EU, and
  // a host from another region would make that sentence false without a single
  // test noticing — so anything else is refused rather than used.
  const host = (env.POSTHOG_HOST ?? DEFAULT_HOST).replace(/\/+$/, "");
  if (!/^https:\/\/eu\.i\.posthog\.com$/.test(host)) {
    log("analytics host refused", { host });
    return { enabled: false, capture() {} };
  }

  return {
    enabled: true,
    capture(event, distinctID, properties = {}, at = Math.floor(Date.now() / 1000)) {
      if (!(Object.values(EVENTS).includes(event) || FUNNEL_EVENTS.has(event)) || !distinctID) return;

      const payload = {
        api_key: key,
        event,
        distinct_id: String(distinctID),
        timestamp: new Date(at * 1000).toISOString(),
        properties: {
          ...pick(properties),
          source: "activation-service",
          $process_person_profile: false,
          $geoip_disable: true,
        },
      };

      const sending = fetcher(`${host}/i/v0/e/`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      })
        .then((response) => {
          if (!response.ok) log("analytics refused", { event, status: response.status });
        })
        .catch((error) => log("analytics failed", { event, reason: String(error?.name ?? "error") }));

      ctx?.waitUntil?.(sending);
      return sending;
    },
  };
}

function pick(properties) {
  const out = {};
  for (const name of ALLOWED_PROPERTIES) {
    if (properties[name] !== undefined && properties[name] !== null) out[name] = properties[name];
  }
  return out;
}

/// Stripe amounts are integers in the currency's smallest unit — except for the
/// currencies that have none, where the integer already is the major unit. The
/// list is Stripe's own; only EUR is sold today, and the rest are here so that
/// changing that is not a silent hundredfold error in revenue.
const ZERO_DECIMAL = new Set([
  "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf",
]);

export function money(amount, currency) {
  if (!Number.isFinite(amount) || typeof currency !== "string" || currency.length !== 3) return {};
  const code = currency.toLowerCase();
  const major = ZERO_DECIMAL.has(code) ? amount : amount / 100;
  return { revenue: Math.round(major * 100) / 100, currency: code.toUpperCase() };
}

/// `PROMO_CODES` is `id=LABEL` pairs separated by commas, where the id is a
/// Stripe coupon or promotion-code id and the label is what shows up in PostHog.
/// A label that is not a short upper-case word is dropped, so a typo in the list
/// can cost a label but never put anything odd on the wire.
const LABEL = /^[A-Z0-9_-]{2,24}$/;

export function promoLabel(promo, env) {
  if (!promo || promo.discounted !== true) return undefined;
  const known = new Map();
  for (const pair of String(env?.PROMO_CODES ?? "").split(",")) {
    const [id, label] = pair.split("=").map((part) => part?.trim());
    if (id && LABEL.test(label ?? "")) known.set(id, label);
  }
  for (const id of promo.ids ?? []) {
    if (known.has(id)) return known.get(id);
  }
  return "other";
}
