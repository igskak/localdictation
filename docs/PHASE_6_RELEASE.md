# Phase 6 — the release path

**Nothing in this file has been run.** It is written from Apple's requirements
and from what the project already contains, and every step is marked with what
would prove it. A release document that claims to have been executed when it has
not is worse than none, because the first person to trust it is the person
shipping.

Both things that blocked it are now settled — the Apple Developer Program
membership is bought and the payment decision is Stripe (`docs/PHASE_8_DECISIONS.md`).
What remains is two credentials on one machine, and `Tools/release.sh` refuses
with a sentence naming whichever of them is missing:

1. A **Developer ID Application** certificate in the login keychain. Xcode →
   Settings → Accounts → Manage Certificates → + → Developer ID Application.
2. A **notarytool keychain profile**, made once from an App Store Connect API
   key:

   ```sh
   xcrun notarytool store-credentials LocalDictationNotary \
     --key ~/private_keys/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer <uuid>
   ```

Then the whole of section 3 and 4 below is one command:

```sh
./Tools/release.sh
```

It reads the Team ID off the certificate rather than carrying it as a constant,
generates `ExportOptions.plist` into `build/`, archives, exports, notarizes and
staples the app, builds and separately notarizes the disk image, and finishes by
printing what `codesign` and `spctl` actually say. It refuses to run from a
dirty working tree, because a release nobody can reproduce is a release whose
version number is a guess.

## What the project already has

- `ENABLE_HARDENED_RUNTIME = YES` in Release, `NO` in Debug. Debug needs it off
  so the debugger can attach; Release needs it on because notarization refuses
  a bundle without it.
- `LSUIElement = true`. The app is an agent, so there is no Dock icon and no
  main window to make a first-run experience out of.
- No App Sandbox, per `AGENTS.md`. Accessibility insertion into other
  applications cannot work inside the sandbox, which is the reason direct
  distribution was chosen over the Mac App Store in the first place.
- `MARKETING_VERSION = 0.1.0`. The version is what a telemetry event carries and
  what an update check would compare, so it stops being decorative here.

## What has to be added

### 1. A Developer ID identity

The membership is bought. What is left is the certificate itself — in Signing &
Capabilities for the Release configuration: *Developer ID Application*,
automatic signing. `security find-identity -v -p codesigning` lists nothing
until that has been done, which is exactly what `Tools/release.sh` checks
first.

Proof: `codesign -dv --verbose=4 LocalDictation.app` names the Developer ID
authority rather than "Apple Development".

### 2. Entitlements

The app needs `com.apple.security.device.audio-input`. It must **not** request
sandbox entitlements. Accessibility is not an entitlement at all — it is a
runtime grant the user makes in System Settings, which is why
`docs/PHASE_4.md` spends as long on it as it does.

Note the development-build consequence already recorded in the README: macOS
keys the Accessibility grant to the code signature, so every rebuild loses it.
A signed release build keeps it across updates as long as the signature is
stable, which is the first user-visible improvement this phase produces.

### 3. Archive, export, notarize, staple

```sh
xcodebuild archive \
  -project LocalDictation.xcodeproj -scheme LocalDictation \
  -configuration Release -archivePath build/LocalDictation.xcarchive

xcodebuild -exportArchive \
  -archivePath build/LocalDictation.xcarchive \
  -exportOptionsPlist Tools/ExportOptions.plist \
  -exportPath build/export

ditto -c -k --keepParent build/export/LocalDictation.app build/LocalDictation.zip

xcrun notarytool submit build/LocalDictation.zip \
  --keychain-profile LocalDictationNotary --wait

xcrun stapler staple build/export/LocalDictation.app
```

`Tools/release.sh` runs all of the above, generating the export options plist
from the Team ID on the certificate. The `LocalDictationNotary` keychain profile
is the one thing it cannot make for you: `notarytool store-credentials` creates
it from an App Store Connect API key, which is the form that does not put an
app-specific password in a shell history.

Proof: `spctl -a -vvv -t install LocalDictation.app` says *accepted, source=
Notarized Developer ID*, and the app opens on a Mac that has never seen it
without a Gatekeeper prompt.

### 4. A disk image

A `.dmg` with the app and a symlink to `/Applications`. It also has to be signed
and stapled in its own right — Gatekeeper checks the container the user actually
downloaded, not only the app inside it. `Tools/release.sh` does both.

The one thing no script can prove: open the image on a Mac that has never seen
this app, from a real download rather than from `build/`. Quarantine only
attaches to a genuine download, so it is the only way the absence of a Gatekeeper
prompt means anything.

### 5. WhisperKit's 600 MB, and what a release changes about it

The model download is user-initiated and lands in Application Support, and none
of that changes. What does change is that a release build is the first one a
user will run without Xcode: the first-run path is *launch → grant microphone →
prepare model → wait for a large download*, and it is the longest wait in the
product. It is worth measuring on a clean Mac before release rather than
discovering it in a support email.

## Updates

**Deferred, with the reason recorded rather than left implicit.**

A signed update channel means Sparkle. `AGENTS.md` forbids a third-party
dependency where the standard frameworks suffice, and here they do not —
macOS ships no updater for direct-distribution apps. But Sparkle brings its own
signing key, its own XPC services, its own appcast hosting, and its own
attack surface, and adopting it before there is a website to host an appcast on
would be adopting it for nothing.

What is worth doing first, and is not built here either, is the small honest
version of it: a version check against a static JSON file, no automatic
download, and a link to the website. That is one network call, it is
enumerable in the privacy policy alongside the model download, and it can be
switched off. Sparkle earns its place when there are enough users that "open
the website and download it again" stops being reasonable.

Until then the release is a download from the product website, and the app does
not check for anything.

## Privacy policy — what must be disclosed before the first public build

`docs/PRODUCT_SCOPE.md` requires every transmitted field, purpose, recipient,
and retention period to be documented. As of this phase the complete list of
things that can leave the Mac is:

| What | When | To whom | Why |
| --- | --- | --- | --- |
| Whisper model weights request | The user presses "Prepare speech model…" | Hugging Face (WhisperKit's host) | Fetching a static asset. One way; nothing is uploaded |
| Email address + device hash | The user presses "Send me a key" | The activation service (`Service/`) | Issuing a license key |
| A license key the user already holds | The user presses "Remove from this Mac" | The same service | Freeing one of the two Macs the license covers |
| The ten product events in `docs/PHASE_6.md` | Not transmitted today | — | Funnel measurement, when a collector exists |

Audio, transcripts, the dictionary, clipboard contents, the names of
applications dictated into, and everything derived from any of them appear
nowhere on that list, and a test asserts the shape of the last row.

The policy itself is written: `docs/PRIVACY.md`, with `PrivacyDisclosureTests`
parsing the request body out of it and comparing the keys to the ones the
encoder actually produces. A field added to the wire without a line in that
document fails the app's test suite.
