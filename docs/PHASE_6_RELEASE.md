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
   xcrun notarytool store-credentials WitnessNotary \
     --key Secrets/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer <uuid>
   ```

   The key id is the ten characters in the filename Apple gives the `.p8`; the
   issuer is the UUID printed above the key list in App Store Connect. They are
   both opaque strings of the wrong shape to tell apart by looking, and putting
   the issuer in `--key-id` is the first mistake everybody makes here.

   `Secrets/` is in the root of the **main checkout** — not in a worktree, which
   can be recycled out from under a download-once credential — so from inside a
   worktree that path has to be absolute. It is ignored by name and by directory
   in both `.gitignore` and `.git/info/exclude` — the second one because it is
   shared by every worktree and applies on every branch, including ones checked
   out before the rule existed. `Tools/release.sh` refuses to build if anything
   credential-shaped has become tracked, because an ignore rule prevents the
   accident and only a check catches the one that already happened.

   Apple issues that `.p8` exactly once. Losing it is recoverable — revoke it
   and make another — which is the opposite of `~/.localdictation/license-signing-key`.

Then the whole of section 3 and 4 below is one command:

```sh
./Tools/release.sh --check   # says what is missing, builds nothing
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

Proof: `codesign -dv --verbose=4 Witness.app` names the Developer ID
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
  -configuration Release -archivePath build/Witness.xcarchive

xcodebuild -exportArchive \
  -archivePath build/Witness.xcarchive \
  -exportOptionsPlist Tools/ExportOptions.plist \
  -exportPath build/export

ditto -c -k --keepParent build/export/Witness.app build/Witness.zip

xcrun notarytool submit build/Witness.zip \
  --keychain-profile WitnessNotary --wait

xcrun stapler staple build/export/Witness.app
```

`Tools/release.sh` runs all of the above, generating the export options plist
from the Team ID on the certificate. The `WitnessNotary` keychain profile
is the one thing it cannot make for you: `notarytool store-credentials` creates
it from an App Store Connect API key, which is the form that does not put an
app-specific password in a shell history.

Proof: `spctl -a -vvv -t install Witness.app` says *accepted, source=
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

### 5. A custom domain for the activation service

**Before the first public build.** `ActivationEndpoint.production` is compiled
into every copy that ships and a shipped copy cannot be told a new address, so
the hostname in it is a promise for the lifetime of that build.

**Done.** It names `api.witnessmac.com`, a Custom Domain declared in
`Service/wrangler.toml`, and `workers_dev` is off so the service has exactly one
address. It used to name a workers.dev hostname — the Cloudflare account's
subdomain plus the worker's name — where either of those changing, or the
service moving off Cloudflare, would strand every installed copy's ability to
start a trial by typing an address. The custom domain has the same property as
the rest of this design: it can be pointed somewhere else later without anybody
reinstalling anything.

What is **not** done is the proof below. It has to happen against the real
deployment before a build carrying this address reaches a stranger.

```sh
npx wrangler deploy   # after adding the route to wrangler.toml
```

Proof: `curl https://<custom host>/v1/health` reports `authority_match: true`,
and `ActivationEndpoint.production` names that host with an `https` scheme —
`HTTPActivationBackendTests` asserts the scheme, because a URL edited to plain
`http` does not leak anything, it silently turns activation off for everyone.

What this does *not* put at risk is a paid copy. Nothing in the checking path
calls the service: a licence is a signature, verified on the Mac. A build whose
endpoint has gone stale still accepts a pasted key and still works on a plane.

### 6. WhisperKit's 600 MB, and what a release changes about it

The model download lands in Application Support, and that does not change. What
does is who starts it: since `docs/REFINEMENTS.md` the app fetches the weights
itself at launch, because a release build is the first one a user will run
without Xcode and the button was a step nobody had been told about. The
first-run path is now *launch → answer the language question → grant the two
permissions the screen asks for → the download that started behind it finishes*,
and it is still the longest wait in the product. It is worth measuring on a
clean Mac before release rather than discovering it in a support email.

## Publishing it

The image is distributed as a GitHub release asset on the public repository,
and the website's download button redirects to it — so the buyer's link stays
on witnessmac.com while the bytes come from GitHub, and no 4 MB binary enters
either repository's history.

**The asset has to be called `Witness.dmg`.** `Tools/release.sh` writes
`build/Witness-$VERSION.dmg`, because a file on this machine should say which
version it is; the *uploaded* one drops the version, because the website points
at

```
https://github.com/<owner>/<repo>/releases/latest/download/Witness.dmg
```

and that address only resolves while an asset by that exact name exists in the
newest release. Uploading `Witness-0.2.0.dmg` and nothing else would leave the
download button pointing at a 404 with every dashboard green — the site would
be serving a redirect to a file that is not there, which looks from the outside
like a working button.

```sh
gh release create v$VERSION \
  build/update-feed/Witness.dmg \
  build/update-feed/appcast.xml \
  --target "$(git rev-parse HEAD)"
```

The tag names the commit the image was actually built from, which is the only
thing that makes `MARKETING_VERSION` more than decoration. Publish the SHA-256
in the notes as well: the signature is what guarantees the file has not been
altered, and the checksum is what a careful buyer can verify before running
anything.

## Updates

Settings now offers a manual **Check for updates** action backed by Sparkle
2.10.0. macOS has no system updater for apps distributed directly by Developer
ID, so Sparkle is the necessary third-party dependency. The licence and bundled
code notices are in `LocalDictation/Resources/Sparkle-LICENSE.txt`; that file
is copied into the app bundle. Automatic checks, automatic installation and
Sparkle system profiling are disabled in `Info.plist`.

The feed URL is the `appcast.xml` asset on the latest GitHub release. The
private Ed25519 seed is `Secrets/sparkle-ed25519.key` by default, ignored by
Git, with its public counterpart embedded as `SUPublicEDKey` in `Info.plist`.
**Back this seed up in a secure place outside the repository before the first
release.** Losing it means an existing app cannot verify a newly signed feed
or update; rotating it needs a separately planned migration. Do not put the
seed in a release asset, commit, issue, or CI log.

`Tools/release.sh` notarizes and staples the Developer ID app and DMG, then
downloads the pinned Sparkle release tools with a verified SHA-256 and creates
`build/update-feed/Witness.dmg` and `build/update-feed/appcast.xml`. Publish
both assets together on `v$VERSION`. The appcast points at the versioned
release URL, while `SUFeedURL` uses the latest release URL. **Increment both
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`** before each release;
Sparkle uses the latter to decide whether an update is newer. Confirm the
release assets are publicly accessible and test an update from the preceding
signed version before telling users it is available.

When releasing from an isolated worktree, `SPARKLE_KEY` can point to the
absolute path of the ignored signing seed in the main checkout. If Xcode's
binary package download stalls on this Mac, `XCODE_SOURCE_PACKAGES_DIR` can
point to an already resolved Xcode `SourcePackages` directory; the release
script passes it to the project build. Keep this path local to the machine.

The current channel must contain only versions a current licence can install.
Before shipping a separately licensed future major version, preserve the old
channel and add an entitlement-aware upgrade path. The existing terms promise
that people can keep using their purchased major version.

## Privacy policy — what must be disclosed before the first public build

`docs/PRODUCT_SCOPE.md` requires every transmitted field, purpose, recipient,
and retention period to be documented. As of this phase the complete list of
things that can leave the Mac is:

| What | When | To whom | Why |
| --- | --- | --- | --- |
| Whisper model weights request | Launch, when the weights are missing — or the user presses "Get the speech model" | Hugging Face (WhisperKit's host) | Fetching a static asset. One way; nothing is uploaded |
| Email address + device hash | The user presses "Send me a key" | The activation service (`Service/`) | Issuing a license key |
| A license key the user already holds | The user presses "Remove from this Mac" | The same service | Freeing one of the two Macs the license covers |
| The ten product events in `docs/PHASE_6.md` | Not transmitted today | — | Funnel measurement, when a collector exists |
| Update catalogue request | Settings button | GitHub Releases | Finds a newer signed version; request URL, IP address, and User-Agent reach GitHub |
| Signed update download | Confirmation in Sparkle's window | GitHub Releases | Downloads the chosen release; request URL, IP address, and User-Agent reach GitHub |

Audio, transcripts, the dictionary, clipboard contents, the names of
applications dictated into, and everything derived from any of them appear
nowhere on that list, and a test asserts the shape of the last row.

The policy itself is written: `docs/PRIVACY.md`, with `PrivacyDisclosureTests`
parsing the request body out of it and comparing the keys to the ones the
encoder actually produces. A field added to the wire without a line in that
document fails the app's test suite.
