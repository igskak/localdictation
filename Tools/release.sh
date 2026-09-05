#!/bin/bash
#
# Archive, sign, notarize, staple, and package Witness for direct
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
#        xcrun notarytool store-credentials WitnessNotary \
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

# The product ships as Witness; the project file and the scheme keep the name
# they were created with, so that renaming the product did not rewrite every
# path in the repository. Both sets of names are correct — the ones below
# address the project, the ones after them name what the build produces.
PROJECT="LocalDictation.xcodeproj"
SCHEME="LocalDictation"
NOTARY_PROFILE="${NOTARY_PROFILE:-WitnessNotary}"
BUILD="build"
ARCHIVE="$BUILD/Witness.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Witness.app"

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

DMG="$BUILD/Witness-$VERSION.dmg"

if [ "$CHECK_ONLY" = "1" ]; then
    echo
    echo "Ready. ./Tools/release.sh would produce $DMG"
    exit 0
fi

# ---------------------------------------------------------------------------
# Archive and export
# ---------------------------------------------------------------------------

step "Archiving"

rm -rf "$ARCHIVE" "$EXPORT" "$BUILD/dmg" "$BUILD/Witness.zip" "$BUILD/Witness-rw.dmg" "$DMG"
mkdir -p "$BUILD"

# `DEVELOPMENT_TEAM` is passed here rather than committed to the project. It
# belongs to whoever is signing, `AGENTS.md` keeps user-specific signing state
# out of the repository, and `Tools/generate_pbxproj.py` would carry a hardcoded
# one forward forever.
#
# `CODE_SIGN_STYLE=Manual` has to be passed with it. The project is on
# automatic signing so that opening it in Xcode needs no setup, and automatic
# signing means *development* signing — naming a Developer ID identity next to
# it is a conflict xcodebuild refuses outright rather than resolving. Manual is
# also the only style that works on this machine: automatic development signing
# wants an Apple Development certificate, and a machine set up to ship has only
# the Developer ID one.
#
# No provisioning profile is specified because direct distribution needs none:
# there is no sandbox, and the one entitlement is not profile-gated.
xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    PROVISIONING_PROFILE_SPECIFIER="" \
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
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
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
#
# This is fatal rather than a warning, which is what it used to be. Hardened
# runtime without the microphone entitlement produces a build that signs,
# notarizes, installs, prompts for the microphone, is granted it, and then
# hears nothing — the runtime refuses input the entitlement does not claim.
# Debug has the hardened runtime off, so dictation works right up until the
# only build a stranger will ever run. A release that fails this check is not
# worth notarizing, and a warning scrolls past.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input" ||
    die "the exported app does not declare com.apple.security.device.audio-input.
  With ENABLE_HARDENED_RUNTIME = YES that build cannot record audio, however
  much permission the user grants it. Check CODE_SIGN_ENTITLEMENTS in the
  Release configuration and LocalDictation/Witness.entitlements."

# ---------------------------------------------------------------------------
# Notarize the app, then the container the user actually downloads
# ---------------------------------------------------------------------------

step "Notarizing the app"

ditto -c -k --keepParent "$APP" "$BUILD/Witness.zip"
xcrun notarytool submit "$BUILD/Witness.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

step "Building the disk image"

rm -rf "$BUILD/dmg"
mkdir -p "$BUILD/dmg/.background"
ditto "$APP" "$BUILD/dmg/Witness.app"
ln -s /Applications "$BUILD/dmg/Applications"
cp Tools/Branding/dmg-background.png "$BUILD/dmg/.background/background.png"

# Read-write first, because the window's appearance is a `.DS_Store` inside the
# image and it cannot be written into a compressed one. It is converted to the
# read-only compressed form at the end.
RW="$BUILD/Witness-rw.dmg"
rm -f "$RW"
hdiutil create \
    -volname "Witness $VERSION" \
    -srcfolder "$BUILD/dmg" \
    -fs HFS+ -format UDRW -ov \
    "$RW" | tail -1

# Only Finder writes a `.DS_Store`, so the icon positions, the window size and
# the background are an AppleScript rather than flags to hdiutil. It needs
# permission to control Finder once, per machine: System Settings, Privacy &
# Security, Automation.
#
# The volume name is read back off the mount rather than assumed. A copy of an
# earlier build left mounted makes macOS append a number, and the difference
# between styling this image and styling that one is invisible until a buyer
# opens an unstyled window.
MOUNT="$(hdiutil attach "$RW" -readwrite -noverify | grep -o '/Volumes/.*' | tail -1)"
[ -d "$MOUNT" ] || die "the read-write image did not mount"
VOLUME="$(basename "$MOUNT")"
echo "   arranging the window of '$VOLUME'"

# The coordinates are the ones drawn into the background by
# `Tools/make_dmg_background.swift`. Both files name them; neither infers them.
osascript - "$VOLUME" <<'APPLESCRIPT' >/dev/null || die "Finder would not arrange the disk image window.
  It needs to be allowed under System Settings -> Privacy & Security ->
  Automation, for whichever terminal is running this. Until then the image is
  correct but its window says nothing, which is the whole reason it exists."
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 840, 520}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:background.png"
            set position of item "Witness.app" of container window to {170, 170}
            set position of item "Applications" of container window to {470, 170}
            close
            open
            update without registering applications
            delay 1
        end tell
    end tell
end run
APPLESCRIPT

# The .DS_Store Finder just wrote is not on disk until this, and converting an
# image whose window settings are still in a buffer produces the unstyled one.
sync
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -ov | tail -1
rm -f "$RW"

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
