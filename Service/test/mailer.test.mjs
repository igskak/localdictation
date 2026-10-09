// The Reply-To header, which a half-filled config can turn into a rejected mail.

import test from "node:test";
import assert from "node:assert/strict";

import { createMailer } from "../src/mailer.js";

async function sentBody(provider, replyTo) {
  const original = globalThis.fetch;
  let body;
  globalThis.fetch = async (request) => {
    body = await request.json();
    return new Response("{}", { status: 200 });
  };
  try {
    const env = { MAIL_PROVIDER: provider, MAIL_API_KEY: "test" };
    if (replyTo !== undefined) env.MAIL_REPLY_TO = replyTo;
    const sent = await createMailer(env).send({ to: "a@example.com", subject: "s", text: "t" });
    assert.equal(sent, true);
    return body;
  } finally {
    globalThis.fetch = original;
  }
}

for (const [provider, field] of [["resend", "reply_to"], ["postmark", "ReplyTo"]]) {
  test(`${provider}: an empty or blank MAIL_REPLY_TO sends no Reply-To at all`, async () => {
    for (const value of [undefined, "", "   "]) {
      const body = await sentBody(provider, value);
      assert.equal(field in body, false, `MAIL_REPLY_TO=${JSON.stringify(value)}`);
    }
  });

  test(`${provider}: a set MAIL_REPLY_TO is sent trimmed`, async () => {
    const body = await sentBody(provider, " hallo@witnessmac.com ");
    assert.equal(body[field], "hallo@witnessmac.com");
  });
}
