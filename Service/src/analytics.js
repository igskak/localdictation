// What this service tells PostHog, and the list that stops it telling more.
//
// Four facts about the business, each the moment it becomes true: a trial was
// issued, a licence was bought, a licence renewed, a licence was refunded. They
// sit on the same dashboard as the website's visits and downloads, so the whole
// path from an ad to money is one screen — as counts over time, not as people.
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
export const ALLOWED_PROPERTIES = ["kind", "revenue", "currency", "provider", "upgrade"];

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
      if (!Object.values(EVENTS).includes(event) || !distinctID) return;

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
