#!/bin/bash
#
# Archive, sign, notarize, staple, and package LocalDictation for direct
# distribution. `docs/PHASE_6_RELEASE.md` is the reasoning; this is the doing.
#
#   ./Tools/release.sh            archive, notarize, staple, package
#   ./Tools/release.sh --check    only say whether this machine could
#
# It needs two things that live on the machine and never in this repository:
#
#   1. A Developer ID Application certificate in the login keychain. Xcode ->
#      Settings -> Accounts -> Manage Certificates -> + -> Developer ID
#      Application. The Team ID is read off it, so there is no constant here to
#      get wrong.
#   2. A notarytool keychain profile, made once:
#
#        xcrun notarytool store-credentials LocalDictationNotary \
#          --key Secrets/AuthKey_XXXXXXXX.p8 \
#          --key-id XXXXXXXX --issuer <issuer-uuid>
#
#      An App Store Connect API key rather than an app-specific password: it is
#      the form that does not put a credential in a shell history. The key id is
#      the ten characters in the filename; the issuer is the UUID above the key
#      list in App Store Connect. Confusing the two is the first mistake
#      everybody makes with this command.
#
#      `Secrets/` sits in the root of the main checkout rather than in a
#      worktree, which can be recycled out from under a download-once
#      credential. It is ignored by name and by directory in both .gitignore
#      and .git/info/exclude, and holds nothing the repository may ever
#      contain. Apple issues that .p8 exactly once.
#
# Everything it produces is under build/, which is not committed.

set -euo pipefail

cd "$(dirname "$0")/.."

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

PROJECT="LocalDictation.xcodeproj"
SCHEME="LocalDictation"
NOTARY_PROFILE="${NOTARY_PROFILE:-LocalDictationNotary}"
BUILD="build"
ARCHIVE="$BUILD/LocalDictation.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/LocalDictation.app"

die() {
    echo "release: $1" >&2
    exit 1
}

step() {
    printf '\n== %s\n' "$1"
}

# ---------------------------------------------------------------------------
# What has to be true before anything is built
# ---------------------------------------------------------------------------

step "Checking the signing identity"

IDENTITY_LINE="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)"
[ -n "$IDENTITY_LINE" ] || die "no Developer ID Application certificate in the keychain.
  Xcode -> Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application.
  A free account cannot issue one; the paid membership can."

IDENTITY="$(echo "$IDENTITY_LINE" | sed -E 's/.*"(.*)".*/\1/')"
TEAM_ID="$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')"
[ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "$IDENTITY" ] || die "could not read a Team ID out of '$IDENTITY'"
echo "   $IDENTITY"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
    die "no notarytool keychain profile called '$NOTARY_PROFILE'.
  Create it with 'xcrun notarytool store-credentials $NOTARY_PROFILE' and an
  App Store Connect API key. See the header of this script."

# The credentials this needs live next to the repository, and the release is the
# moment to be sure none of them has been committed. An ignore rule protects
# against an accident; this catches the accident that already happened.
TRACKED_SECRETS="$(git ls-files | grep -iE '\.p8$|\.p12$|\.provisionprofile$|AuthKey' || true)"
[ -z "$TRACKED_SECRETS" ] || die "these are tracked by git and must not be:
$TRACKED_SECRETS
  Remove them from the index with 'git rm --cached', and rotate them: anything
  that has been committed has to be assumed public."


# A release built from uncommitted work is a release nobody can reproduce, and
# the version it claims to be is a guess.
if [ -n "$(git status --porcelain)" ] && [ "${ALLOW_DIRTY:-0}" != "1" ] && [ "$CHECK_ONLY" = "0" ]; then
    die "the working tree has uncommitted changes. Commit them, or re-run with ALLOW_DIRTY=1."
fi

VERSION="$(
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null |
        awk '/ MARKETING_VERSION = /{print $3; exit}'
)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION out of the project"
echo "   version $VERSION, team $TEAM_ID"

DMG="$BUILD/LocalDictation-$VERSION.dmg"

if [ "$CHECK_ONLY" = "1" ]; then
    echo
    echo "Ready. ./Tools/release.sh would produce $DMG"
    exit 0
fi

# ---------------------------------------------------------------------------
# Archive and export
# ---------------------------------------------------------------------------

step "Archiving"

rm -rf "$ARCHIVE" "$EXPORT" "$BUILD/dmg" "$BUILD/LocalDictation.zip" "$DMG"
mkdir -p "$BUILD"

# `DEVELOPMENT_TEAM` is passed here rather than committed to the project. It
# belongs to whoever is signing, `AGENTS.md` keeps user-specific signing state
# out of the repository, and `Tools/generate_pbxproj.py` would carry a hardcoded
# one forward forever.
xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    | tail -5

step "Exporting"

# Generated rather than committed: the Team ID belongs to whoever is signing,
# and a checked-in placeholder is a file that breaks the export the first time
# somebody trusts it.
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$EXPORT" \
    | tail -5

[ -d "$APP" ] || die "the export produced no app at $APP"

# The hardened runtime is on in Release and off in Debug — the debugger cannot
# attach with it on, and notarization refuses a bundle without it. Worth
# checking here rather than reading a rejection email about it.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input" ||
    echo "   warning: the app does not declare the microphone entitlement"

# ---------------------------------------------------------------------------
# Notarize the app, then the container the user actually downloads
# ---------------------------------------------------------------------------

step "Notarizing the app"

ditto -c -k --keepParent "$APP" "$BUILD/LocalDictation.zip"
xcrun notarytool submit "$BUILD/LocalDictation.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

step "Building the disk image"

rm -rf "$BUILD/dmg"
mkdir -p "$BUILD/dmg"
ditto "$APP" "$BUILD/dmg/LocalDictation.app"
ln -s /Applications "$BUILD/dmg/Applications"

hdiutil create \
    -volname "LocalDictation $VERSION" \
    -srcfolder "$BUILD/dmg" \
    -fs HFS+ -format UDZO -ov \
    "$DMG" | tail -2

# Gatekeeper checks the container that was downloaded, so the image is signed
# and stapled in its own right and not just the app inside it.
step "Notarizing the disk image"

codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------------------
# Proof, rather than the belief that it worked
# ---------------------------------------------------------------------------

step "Verifying"

codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp" || true
echo
spctl -a -vvv -t install "$APP"
spctl -a -vvv -t open --context context:primary-signature "$DMG" || true

cat <<DONE

Done: $DMG

Two things this script cannot check for you:
  - Open the image on a Mac that has never seen this app, from a download
    rather than from this directory, and confirm there is no Gatekeeper
    prompt. Quarantine only attaches to a real download.
  - docs/PHASE_6_RELEASE.md asks for the first-run measurement on a clean Mac
    that has never fetched the speech model. It is the longest wait in the
    product and it is better measured than guessed.
DONE
