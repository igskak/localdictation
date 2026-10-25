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
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
    ENABLE_HARDENED_RUNTIME=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
compilation_conditions='$(inherited) WITNESS_PHASE_9_1_PREVIEW'
if [ "${NOTETAKER_DOGFOOD:-0}" = 1 ]; then
    compilation_conditions="$compilation_conditions NOTETAKER_DOGFOOD NOTETAKER_DIARIZATION"
fi
# Automatic speaker numbers for transcribed files: off in every ordinary build
# until the F2 gate has data (docs/FILE_TRANSCRIPTION_PLAN.md). A dogfood build
# can switch them on to look at the result; they need the bundled model above.
if [ "${NOTETAKER_DOGFOOD:-0}" = 1 ] && [ "${FILE_SPEAKER_LABELS:-0}" = 1 ]; then
    compilation_conditions="$compilation_conditions FILE_SPEAKER_LABELS"
fi
build_args+=(SWIFT_ACTIVE_COMPILATION_CONDITIONS="$compilation_conditions")

xcodebuild "${build_args[@]}" ${package_args[@]+"${package_args[@]}"} build
settings=$(xcodebuild "${build_args[@]}" ${package_args[@]+"${package_args[@]}"} -showBuildSettings)
products=$(printf '%s\n' "$settings" | awk -F ' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / {print $2; exit}')
built_app="$products/Witness.app"
[ -d "$built_app" ] || { echo "Missing build product: $built_app" >&2; exit 1; }

# Library validation in a hardened ad-hoc app rejects embedded frameworks that
# have no matching Team ID. Verify the build override before packaging it.
signature=$(codesign -dv --verbose=2 "$built_app" 2>&1)
case "$signature" in
    *'flags=0x2(adhoc)'*) ;;
    *) echo 'Expected an ad-hoc signature without hardened runtime.' >&2; exit 1 ;;
esac
codesign --verify --deep --strict "$built_app"

mkdir -p build
revision=$(git rev-parse --short HEAD)
dmg=${1:-"build/Witness-test-$revision.dmg"}
[ ! -e "$dmg" ] || { echo "Output already exists: $dmg" >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/witness-test-dmg.XXXXXX")
model_stage=$(mktemp -d "${TMPDIR:-/tmp}/witness-nemotron3.XXXXXX")
cleanup() { rm -rf "$stage" "$model_stage"; }
trap cleanup EXIT
ditto "$built_app" "$stage/Witness.app"
app="$stage/Witness.app"
if [ "${NOTETAKER_DOGFOOD:-0}" = 1 ]; then
    if [ -n "${NEMOTRON3_MODEL_SOURCE_DIR:-}" ]; then
        [ -d "$NEMOTRON3_MODEL_SOURCE_DIR" ] || {
            echo "Missing model source directory: $NEMOTRON3_MODEL_SOURCE_DIR" >&2
            exit 1
        }
        ditto "$NEMOTRON3_MODEL_SOURCE_DIR" "$model_stage/Nemotron3"
    fi
    Tools/prepare_nemotron3_model.sh "$model_stage/Nemotron3" >/dev/null
    ditto "$model_stage/Nemotron3" "$app/Contents/Resources/Nemotron3"
    codesign --force --deep --sign - "$app"
    codesign --verify --deep --strict "$app"
fi
ln -s /Applications "$stage/Applications"
hdiutil create -volname 'Witness Test' -srcfolder "$stage" -format UDZO "$dmg"
hdiutil verify "$dmg"
printf '\nTest DMG: %s\n' "$dmg"
printf '%s\n' 'Ad-hoc signed and not notarized; do not distribute as a release.'
