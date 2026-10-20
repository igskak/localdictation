// The two things this service ever asks Stripe to do.
//
// Everything else Stripe tells us arrives as a webhook. These are the exceptions
// because they are actions rather than news:
//
//   - a refund or a dispute cancels the subscription behind the licence, so a
//     buyer who got the €4.99 back is not charged €49 on the fifteenth day;
//   - a cancellation asked for on the website stops renewal at the end of the
//     paid period.
//
// `STRIPE_API_KEY` is a *restricted* key that can write Subscriptions and
// nothing else. With it unset, both calls report that they did nothing, and the
// caller says so in the log; the licence side of a refund still happens.

const API = "https://api.stripe.com/v1";

export function createBilling(env, log = () => {}) {
  const key = env.STRIPE_API_KEY?.trim();
  if (!key) {
    return {
      configured: false,
      async cancelNow() {
        log("subscription not cancelled (no Stripe key configured)");
        return false;
      },
      async cancelAtPeriodEnd() {
        log("subscription not cancelled (no Stripe key configured)");
        return false;
      },
    };
  }

  async function call(method, path, form) {
    const response = await fetch(`${API}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form ? new URLSearchParams(form).toString() : undefined,
    });
    // 404 is "already gone", which is the state we wanted; anything else that
    // is not a success is reported to the caller as a failure and never thrown,
    // because the webhook that called this must still acknowledge its event.
    if (response.ok || response.status === 404) return true;
    log("stripe refused a subscription call", { status: response.status });
    return false;
  }

  return {
    configured: true,
    /// For a refund: the subscription ends now and nothing further is charged.
    async cancelNow(subscriptionID) {
      return call("DELETE", `/subscriptions/${encodeURIComponent(subscriptionID)}`);
    },
    /// For a cancellation the customer asked for: paid time is honoured.
    async cancelAtPeriodEnd(subscriptionID) {
      return call("POST", `/subscriptions/${encodeURIComponent(subscriptionID)}`, { cancel_at_period_end: "true" });
    },
  };
}
