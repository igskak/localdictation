// Answers, in the one shape the client knows how to read.
//
// Every reply is JSON, on one origin, with no redirect: `HTTPActivationBackend`
// refuses a 200 that is not a key and refuses anything over 8 KB, so a service
// that answers with an HTML error page or a redirect to a login screen is a
// service the app can only report as broken.

export const MAXIMUM_REQUEST_BYTES = 4 * 1024;

export function json(status, body, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}

/// Reads a JSON body, bounded. Returns `null` for anything that is not an
/// object — the caller turns that into the same refusal a missing field gets,
/// because from the user's side they are the same mistake.
export async function readJSON(request) {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAXIMUM_REQUEST_BYTES) return null;

  const text = await request.text();
  if (text.length > MAXIMUM_REQUEST_BYTES) return null;

  try {
    const value = JSON.parse(text);
    if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
    return value;
  } catch {
    return null;
  }
}

/// The address a rate-limit counter is kept under. Cloudflare sets
/// `CF-Connecting-IP`; anything else is a header a caller can write, so it is
/// only used when there is nothing better and the counter is per-day either way.
export function clientAddress(request) {
  return request.headers.get("CF-Connecting-IP") ?? request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ?? "unknown";
}
