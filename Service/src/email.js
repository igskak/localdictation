// The address, and the two things done to it.
//
// The shape check mirrors `EmailAddress.looksComplete` in the app, deliberately
// — a rule the client applies and the service does not is a rule that gives two
// different answers to the same typo. It is permissive on purpose: an address
// is checked by the thing that delivers mail to it, and a regular expression
// here can only reject valid addresses somebody actually owns.

export const MAXIMUM_LENGTH = 254;

/// What the address is stored and looked up under. Lowercased, because someone
/// who bought as `Someone@Example.com` and activates as `someone@example.com`
/// is one customer.
///
/// It is also what goes into the key's payload, so that pressing the button
/// twice with different capitalisation produces the same bytes, and therefore
/// the same key, rather than a second one.
export function normalizeEmail(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!looksComplete(trimmed)) return null;
  return trimmed.toLowerCase();
}

export function looksComplete(value) {
  if (typeof value !== "string") return false;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > MAXIMUM_LENGTH) return false;
  // Whitespace anywhere, or a control character, is a paste accident
  // rather than an address. Nothing else is rejected on shape: `+` tags,
  // apostrophes and long top-level domains are all addresses somebody
  // reads their mail at.
  if (/\s/.test(trimmed)) return false;
  if (/[\u0000-\u001f\u007f]/.test(trimmed)) return false;

  const at = trimmed.indexOf("@");
  if (at <= 0) return false;
  const domain = trimmed.slice(at + 1);
  if (domain.includes("@")) return false;

  const dot = domain.indexOf(".");
  if (dot <= 0) return false;
  return dot < domain.length - 1;
}
