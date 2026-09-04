// Delivering the key.
//
// The reply to `POST /v1/activate` is what unlocks the app; the mail is what
// the user still has when they replace the Mac. So a mailer that is down does
// not fail an activation — it is logged, `mailed_at` stays NULL, and the next
// press of the button sends it.
//
// Transactional only. Marketing to an address collected here needs its own
// consent; in Germany that is §7 UWG and not a formality.

const PROVIDERS = ["resend", "postmark", "none"];

/// Chosen by `MAIL_PROVIDER`, so swapping Resend for Postmark is an environment
/// variable rather than a deploy of different code.
export function createMailer(env, log = () => {}) {
  const provider = (env.MAIL_PROVIDER ?? "none").toLowerCase();
  if (!PROVIDERS.includes(provider)) throw new Error(`MAIL_PROVIDER must be one of ${PROVIDERS.join(", ")}`);

  const from = env.MAIL_FROM ?? "Witness <keys@witnessmac.com>";
  const replyTo = env.MAIL_REPLY_TO ?? null;

  if (provider === "none") {
    return {
      provider,
      async send({ to, subject }) {
        // Deliberately never the address: a log line that carries one is a log
        // line that has to be retained like the licence table.
        log("mail skipped (no provider configured)", { subject, recipients: to ? 1 : 0 });
        return false;
      },
    };
  }

  return {
    provider,
    async send({ to, subject, text }) {
      const request =
        provider === "resend"
          ? new Request("https://api.resend.com/emails", {
              method: "POST",
              headers: {
                Authorization: `Bearer ${env.MAIL_API_KEY ?? ""}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({ from, to: [to], subject, text, reply_to: replyTo ?? undefined }),
            })
          : new Request("https://api.postmarkapp.com/email", {
              method: "POST",
              headers: {
                "X-Postmark-Server-Token": env.MAIL_API_KEY ?? "",
                "Content-Type": "application/json",
                Accept: "application/json",
              },
              body: JSON.stringify({
                From: from,
                To: to,
                Subject: subject,
                TextBody: text,
                ReplyTo: replyTo ?? undefined,
                MessageStream: env.MAIL_STREAM ?? "outbound",
              }),
            });

      const response = await fetch(request);
      if (!response.ok) {
        log("mail refused by the provider", { provider, status: response.status });
        return false;
      }
      return true;
    },
  };
}

/// The key, and the one sentence about what to do with it.
export function activationMail({ key, kind, expiresAt }) {
  const term =
    kind === "lifetime"
      ? "It does not expire."
      : `It runs until ${formatDate(expiresAt)}.`;
  const heading = kind === "trial" ? "Your Witness trial key" : "Your Witness key";

  return {
    subject: heading,
    text: [
      "Here is the key for the Mac you activated from.",
      "",
      key,
      "",
      `A key is issued for one Mac, and a license covers two. ${term}`,
      "",
      "If the app did not unlock by itself, open Witness, then Settings, then",
      "License, and paste the line above into 'Enter a key'.",
      "",
      "Keep this mail. It is what you use when you replace the Mac.",
      "",
      "This is a transactional message about a key you asked for. It is not a",
      "mailing list and there is nothing to unsubscribe from.",
    ].join("\n"),
  };
}

/// What a buyer gets. It carries no key, because at the moment of purchase
/// nobody knows which Mac to name in one — which is the sentence this whole
/// design costs, and it belongs here rather than being discovered.
export function purchaseMail({ kind, expiresAt }) {
  const term = kind === "lifetime" ? "a lifetime license" : `an annual license until ${formatDate(expiresAt)}`;

  return {
    subject: "Your Witness license — one step to finish",
    text: [
      `Thank you. This address now holds ${term}.`,
      "",
      "A key names one Mac, and a browser cannot know which. So the last step",
      "happens in the app:",
      "",
      "  1. Open Witness.",
      "  2. Settings, then License.",
      "  3. Type this address and press 'Send my key'.",
      "",
      "The key arrives by mail as well, and the app unlocks straight away. Repeat",
      "it on your second Mac whenever you like — a license covers two.",
      "",
      "This is a transactional message about a purchase you made.",
    ].join("\n"),
  };
}

/// What a renewal gets, and the reason it is not silent.
///
/// A key carries the date it was issued against, so the key on a subscriber's
/// Mac still expires on the old date even though the licence no longer does.
/// One press of Send my key replaces it. The app warns two weeks ahead as well,
/// but the person who set this up a year ago is not reading the menu.
export function renewalMail({ expiresAt }) {
  return {
    subject: "Witness renewed — refresh the key on your Macs",
    text: [
      `Your licence is renewed until ${formatDate(expiresAt)}. Nothing was charged twice and`,
      "nothing needs cancelling.",
      "",
      "One step, on each Mac you use it on:",
      "",
      "  1. Open Witness.",
      "  2. Settings, then License.",
      "  3. Type this address and press 'Send my key'.",
      "",
      "That replaces the key on the Mac with one that runs to the new date. A key",
      "is checked on your Mac and not against us, which is why it has a date in it",
      "at all -- and why this step exists.",
      "",
      "This is a transactional message about a subscription you hold.",
    ].join("\n"),
  };
}

function formatDate(seconds) {
  if (!Number.isFinite(seconds)) return "its date";
  return new Date(seconds * 1000).toISOString().slice(0, 10);
}
