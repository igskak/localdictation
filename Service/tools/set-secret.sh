#!/bin/bash
#
# Sets one of this service's secrets without its value ever touching a command
# line, an argument list, or a shell history.
#
#   ./tools/set-secret.sh WEBHOOK_SECRET
#
# The one thing you type is the value, at a prompt, and it is not echoed.
#
# This exists because `wrangler secret put` takes the *name* as its argument and
# reads the value from stdin, and that is one character away from a mistake with
# real consequences. Both of them happened while this service was being set up:
#
#   wrangler secret put WEBHOOK_SECRET --env="whsec_..."   -> the value went
#       into a flag, so into the shell history and into wrangler's own log
#   wrangler secret put whsec_...                          -> the value became
#       the secret's *name*, and names are not secret: `secret list` prints
#       them, and WEBHOOK_SECRET was never set at all, so every webhook was
#       rejected while everything looked configured
#
# Neither is possible here: the argument must be a known name, anything
# value-shaped in it is refused, and the value is read with `read -s`.

set -euo pipefail

cd "$(dirname "$0")/.."

die() {
    echo "set-secret: $1" >&2
    exit 1
}

NAME="${1:-}"
[ $# -eq 1 ] || die "one argument, the NAME of the secret. The value is typed at a prompt.
  usage: ./tools/set-secret.sh WEBHOOK_SECRET"

# A value pasted where the name goes is the mistake this is here to stop, and
# every credential this service holds has a recognisable prefix.
case "$NAME" in
    whsec_* | sk_* | rk_* | re_* | pk_*)
        die "that looks like a secret's *value*, not its name.
  The name is what goes on the command line; the value is typed at the prompt.
  Roll it at the provider before using it: a value that has been in an argument
  list is in your shell history."
        ;;
esac

case "$NAME" in
    WEBHOOK_SECRET | LICENSE_SIGNING_KEY | MAIL_API_KEY) ;;
    *)
        die "unknown secret '$NAME'.
  This service has three: WEBHOOK_SECRET, LICENSE_SIGNING_KEY, MAIL_API_KEY.
  Anything else is a typo, and a typo here creates a secret nothing reads while
  leaving the real one unset."
        ;;
esac

printf 'Value for %s (not echoed): ' "$NAME"
read -r -s VALUE
echo

[ -n "$VALUE" ] || die "nothing was typed, so nothing was set"

# Shape checks, per secret. A wrong value here fails silently in production:
# a bad webhook secret rejects every real purchase, and a bad signing key issues
# licence keys that verify on nobody's Mac.
case "$NAME" in
    WEBHOOK_SECRET)
        case "$VALUE" in
            whsec_*) ;;
            *) die "a Stripe webhook signing secret starts with 'whsec_'. Reveal it on the endpoint's own page." ;;
        esac
        ;;
    LICENSE_SIGNING_KEY)
        # base64 of a raw 32-byte Ed25519 seed is exactly 44 characters.
        [ "${#VALUE}" -eq 44 ] || die "the signing key is 44 characters, the base64 of a 32-byte seed.
  It is the contents of ~/.localdictation/license-signing-key, and it should be
  piped from that file rather than retyped:
    cat ~/.localdictation/license-signing-key | npx wrangler secret put LICENSE_SIGNING_KEY"
        ;;
esac

printf '%s' "$VALUE" | WRANGLER_SEND_METRICS=false npx wrangler secret put "$NAME"

echo
echo "Set. Names in this service now:"
WRANGLER_SEND_METRICS=false npx wrangler secret list 2>/dev/null |
    grep '"name"' |
    sed 's/.*: "/  /; s/",*$//'
echo
echo "Any name above that looks like a value is a mistake, and its value is"
echo "public: roll it at the provider and remove it with"
echo "  npx wrangler secret delete <that name>"
