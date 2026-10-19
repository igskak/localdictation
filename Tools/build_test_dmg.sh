#!/bin/bash
# Build a local, ad-hoc-signed DMG. This is not a notarized release; use
# release.sh for distribution with a Developer ID and hardened runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

package_args=()
if [ -n "${XCODE_SOURCE_PACKAGES_DIR:-}" ]; then
    package_args=(-clonedSourcePackagesDirPath "$XCODE_SOURCE_PACKAGES_DIR")
fi
build_args=(-project LocalDictation.xcodeproj -scheme LocalDictation
    -configuration Release -destination 'platform=macOS,arch=arm64'
    ENABLE_HARDENED_RUNTIME=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)

xcodebuild "${build_args[@]}" ${package_args[@]+"${package_args[@]}"} build
settings=$(xcodebuild "${build_args[@]}" ${package_args[@]+"${package_args[@]}"} -showBuildSettings)
products=$(printf '%s\n' "$settings" | awk -F ' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / {print $2; exit}')
app="$products/Witness.app"
[ -d "$app" ] || { echo "Missing build product: $app" >&2; exit 1; }

# Library validation in a hardened ad-hoc app rejects embedded frameworks that
# have no matching Team ID. Verify the build override before packaging it.
signature=$(codesign -dv --verbose=2 "$app" 2>&1)
case "$signature" in
    *'flags=0x2(adhoc)'*) ;;
    *) echo 'Expected an ad-hoc signature without hardened runtime.' >&2; exit 1 ;;
esac
codesign --verify --deep --strict "$app"

mkdir -p build
revision=$(git rev-parse --short HEAD)
dmg=${1:-"build/Witness-test-$revision.dmg"}
[ ! -e "$dmg" ] || { echo "Output already exists: $dmg" >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/witness-test-dmg.XXXXXX")
ditto "$app" "$stage/Witness.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname 'Witness Test' -srcfolder "$stage" -format UDZO "$dmg"
hdiutil verify "$dmg"
printf '\nTest DMG: %s\n' "$dmg"
printf '%s\n' 'Ad-hoc signed and not notarized; do not distribute as a release.'
