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
  // `??` alone would let `MAIL_REPLY_TO = ""` through, and an empty Reply-To is
  // a header the provider rejects rather than ignores. Unset and set to nothing
  // have to mean the same thing.
  const replyTo = env.MAIL_REPLY_TO?.trim() || null;

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
///
/// It also carries the withdrawal paragraph, because this is the only durable
/// thing a buyer keeps from the purchase that we write. The declaration itself
/// is made in the app, before it opens a checkout — Stripe's Managed Payments
/// checkout is standardized and takes no custom text, so it could not be made
/// there. See `docs/PHASE_8_DECISIONS.md` D5.
///
/// The paragraph is deliberately conditional. This service is not told whether
/// the declaration was made: the app sends two fields and neither is this one,
/// and a Payment Link opened from outside the app shows no declaration at all.
/// So the mail says what the app asks and what follows if it was never asked —
/// which is true in both cases, rather than confirming something nobody here
/// knows happened.
export function purchaseMail({ kind, expiresAt, intro = false }) {
  return intro ? introPurchaseMail({ expiresAt }) : standardPurchaseMail({ kind, expiresAt });
}

/// What somebody gets who paid EUR 4.99 on `/start`.
///
/// German first and English under it, because the page is sold in both and the
/// buyer's language is not in the payment. It says the buyer has the statutory
/// fourteen days of withdrawal: the order page no longer asks them to give it up. It is built around the one thing that
/// goes wrong for these buyers: the app does not know they paid for the first
/// three days, and on day three it asks for an address. An address other than the
/// one they paid with gets them a free trial instead of their subscription, and
/// Stripe still charges EUR 49 on day 15. So that sentence is the biggest thing
/// in the mail, and the download link is in it because there is no other copy of
/// it once the thanks page is closed.
function introPurchaseMail({ expiresAt }) {
  const until = formatDate(expiresAt);
  const rule = "=".repeat(60);

  return {
    subject: "Witness: dein Download und ein Schritt in der App / your download and one step in the app",
    text: [
      "Danke für deinen Kauf.",
      "",
      rule,
      "WICHTIG: Gib in Witness die E-Mail-Adresse ein, mit der du bezahlt hast",
      "(diese hier). Mit einer anderen Adresse erkennt Witness deinen Kauf nicht.",
      rule,
      "",
      "Download: https://witnessmac.com/download",
      "",
      "So geht es weiter:",
      "  1. Witness laden, öffnen, in den Ordner Programme ziehen.",
      "  2. Die ersten drei Tage fragt Witness nach nichts.",
      "  3. Am dritten Tag bittet es um deine E-Mail-Adresse. Gib diese hier ein,",
      "     dann ist dein Abonnement aktiv. Das geht auch jederzeit vorher unter",
      "     Einstellungen, Lizenz, „Schlüssel anfordern“.",
      "",
      `Dein Zugang ist bis ${until} bezahlt. Danach zieht Stripe automatisch €49 für ein Jahr ein,`,
      "wenn du nicht bis zum 14. Tag kündigst. Kündigst du bis dahin, zahlst du nur die €4,99.",
      "Kündigen: https://witnessmac.com/kuendigen",
      "Zahlung und Rechnungen verwalten: https://witnessmac.com/manage",
      "",
      "Dein Widerrufsrecht: Du kannst diesen Vertrag innerhalb von 14 Tagen ab dem Kauf ohne",
      "Angabe von Gründen widerrufen, auch wenn du Witness schon benutzt hast. Eine E-Mail an",
      "hallo@witnessmac.com mit der Adresse, unter der du gekauft hast, genügt; du bekommst das",
      "Geld zurück, und die Lizenz endet.",
      "Widerrufsbelehrung: https://witnessmac.com/widerruf",
      "",
      "",
      "Thank you for your purchase.",
      "",
      rule,
      "IMPORTANT: In Witness, enter the email address you paid with (this one).",
      "With a different address Witness does not recognise your purchase.",
      rule,
      "",
      "Download: https://witnessmac.com/download",
      "",
      "What happens next:",
      "  1. Download Witness, open it, drag it into the Applications folder.",
      "  2. For the first three days Witness asks for nothing.",
      "  3. On day three it asks for your email address. Enter this one and your",
      "     subscription is active. You can also do it any time before, under",
      "     Settings, License, “Send me a key”.",
      "",
      `Your access is paid until ${until}. After that Stripe automatically charges EUR 49 for a year`,
      "unless you cancel by day 14. If you cancel by then you pay only the EUR 4.99.",
      "Cancel: https://witnessmac.com/en/cancel-subscription",
      "Manage payment and invoices: https://witnessmac.com/manage",
      "",
      "Your right of withdrawal: you can withdraw from this contract within 14 days of the purchase,",
      "without giving a reason, even if you have already used Witness. An email to",
      "hallo@witnessmac.com naming the address you bought with is enough; you get the money back and",
      "the licence ends.",
      "Withdrawal instruction: https://witnessmac.com/en/cancellation",
      "",
      "This is a transactional message about a purchase you made.",
    ].join("\n"),
  };
}

function standardPurchaseMail({ kind, expiresAt }) {
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
      "Your right of withdrawal",
      "",
      "Witness asks for one declaration before it opens a checkout: that the key",
      "be delivered straight away, and that asking for this gives up the",
      "statutory right of withdrawal. If you bought from inside the app, that is",
      "what you agreed to, and this mail is your confirmation of it:",
      "",
      "  Ich verlange ausdrücklich die sofortige Ausführung des Vertrags und",
      "  bestätige, dass ich dadurch mein Widerrufsrecht verliere.",
      "",
      "If you never saw that declaration, it was not made, and your right of",
      "withdrawal runs the full fourteen days from today.",
      "",
      "  Terms: https://witnessmac.com/en/terms",
      "  Right of withdrawal: https://witnessmac.com/en/cancellation",
      "",
      "This is a transactional message about a purchase you made.",
    ].join("\n"),
  };
}

/// What a renewal gets.
///
/// Since the thirty-day keys, Witness fetches the new key by itself, so the mail
/// asks for nothing. It is still sent: it is the receipt that the year began and
/// the place a person finds how to stop the next one.
export function renewalMail({ expiresAt }) {
  return {
    subject: "Witness renewed",
    text: [
      `Your subscription is renewed until ${formatDate(expiresAt)}.`,
      "",
      "There is nothing to do. Witness picks up its new key by itself the next",
      "time it is open with an internet connection.",
      "",
      "You can cancel any time, and the paid time stays yours:",
      "",
      "  https://witnessmac.com/kuendigen",
      "",
      "This is a transactional message about a subscription you hold.",
    ].join("\n"),
  };
}

/// What somebody who asked to cancel on the website is sent, at once. §312k BGB
/// wants the confirmation in text form with the date and time, and says when
/// the contract ends.
export function cancellationMail({ endsAt, at }) {
  return {
    subject: "Witness: your cancellation was received",
    text: [
      `We received your cancellation on ${formatDateTime(at)}.`,
      "",
      `Your subscription does not renew. Witness keeps working until ${formatDate(endsAt)}, the end of the period you paid for.`,
      "",
      "Changed your mind? Until that date you can resume the subscription from",
      "Witness, Settings, License, Manage subscription.",
      "",
      "This is a transactional message about a subscription you hold.",
    ].join("\n"),
  };
}

function formatDateTime(seconds) {
  if (!Number.isFinite(seconds)) return "this date";
  return `${new Date(seconds * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC`;
}

function formatDate(seconds) {
  if (!Number.isFinite(seconds)) return "its date";
  return new Date(seconds * 1000).toISOString().slice(0, 10);
}
