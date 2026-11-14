#!/bin/bash
# Builds a self-contained ImageSearch.app and wraps it in a disk image that can
# be attached to a GitHub release.
#
#   bash scripts/build-dmg.sh
#
# Unlike build-app.sh, the result does not depend on this checkout: the app is
# one Swift binary plus the Core ML models listed in BUNDLE_MODELS, and it
# keeps its settings in ~/Library/Application Support/ImageSearch. No Python.
#
# Optional environment:
#   APP_VERSION          version to stamp (default: macos/VERSION)
#   BUNDLE_MODELS        models to ship inside the app, space separated
#                        (default: clip-vit-b32). MobileCLIP-S4 is left out by
#                        default because Apple licenses its weights for
#                        research use only; add it only if that fits how you
#                        distribute the app: BUNDLE_MODELS="mobileclip-s4 clip-vit-b32"
#   MODELS_URL           address serving models/coreml/, from which the app
#                        may download models it does not carry
#   CODESIGN_IDENTITY    "Developer ID Application: …" to sign for distribution
#                        (default: ad-hoc; Gatekeeper will warn on other Macs)
#   NOTARY_PROFILE       notarytool keychain profile; notarises and staples the
#                        disk image (needs CODESIGN_IDENTITY)
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$IMGSEARCH_PROJECT_ROOT"

VERSION="${APP_VERSION:-$(cat macos/VERSION)}"
ARCH="$(uname -m)"
STAGE="$IMGSEARCH_PROJECT_ROOT/dist/standalone"
APP="$STAGE/ImageSearch.app"
RESOURCES="$APP/Contents/Resources"
DMG="$IMGSEARCH_PROJECT_ROOT/dist/ImageSearch-$VERSION-$ARCH.dmg"
read -r -a MODELS <<<"${BUNDLE_MODELS-clip-vit-b32}"

step() { printf '\n==> %s\n' "$1"; }

if [[ "$ARCH" != "arm64" ]]; then
  echo "ImageSearch only runs on Apple Silicon; build on an arm64 Mac." >&2
  exit 1
fi
if [[ ${#MODELS[@]} -eq 0 && -z "${MODELS_URL:-}" ]]; then
  echo "With no BUNDLE_MODELS and no MODELS_URL the app would have no model to search with." >&2
  exit 1
fi

step "Building the app ($VERSION)"
mkdir -p .cache/clang .cache/swift
export CLANG_MODULE_CACHE_PATH="$IMGSEARCH_PROJECT_ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$IMGSEARCH_PROJECT_ROOT/.cache/swift"
swift build --package-path macos -c release
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"
cp macos/.build/release/ImageSearch "$APP/Contents/MacOS/ImageSearch"
cp macos/AppIcon.icns "$RESOURCES/AppIcon.icns"
if [[ -n "${MODELS_URL:-}" ]]; then
  bash scripts/info-plist.sh "$APP" "$VERSION" --models-url "$MODELS_URL"
else
  bash scripts/info-plist.sh "$APP" "$VERSION"
fi

step "Adding models (${MODELS[*]:-none})"
for model in ${MODELS[@]+"${MODELS[@]}"}; do
  source_dir="models/coreml/$model"
  if [[ ! -f "$source_dir/model.json" ]]; then
    bash scripts/convert-models.sh "$model"
  fi
  mkdir -p "$RESOURCES/models/$model"
  # Test fixtures and the download listing are not needed to run the model.
  rsync -a --exclude fixtures.json --exclude files.json --exclude '.*' \
    "$source_dir/" "$RESOURCES/models/$model/"
  printf '  %-16s %s  (%s)\n' "$model" "$(du -sh "$RESOURCES/models/$model" | cut -f1)" \
    "$(plutil -extract license raw "$source_dir/model.json")"
done

step "Signing"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  # Distribution: the identity, the hardened runtime and a timestamp.
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
  echo "  ad-hoc signature: other Macs will ask the user to confirm opening the app"
fi
codesign --verify --deep --strict "$APP"

step "Checking the app works without this checkout"
# A bare environment, a neutral directory and a throwaway data folder: nothing
# here can reach the checkout, so the app must index and search with only what
# is inside it.
if [[ ${#MODELS[@]} -gt 0 ]]; then
  SELF_TEST_DATA="$(mktemp -d "$TMPDIR/imagesearch-self-test.XXXXXX")"
  (cd / && env -i HOME="$HOME" PATH=/usr/bin:/bin IMGSEARCH_DATA_ROOT="$SELF_TEST_DATA" \
    "$APP/Contents/MacOS/ImageSearch" --self-test | sed 's/^/  /')
  rm -rf "$SELF_TEST_DATA"
else
  echo "  skipped: this build carries no model and downloads them from $MODELS_URL"
fi

step "Creating the disk image"
IMAGE_ROOT="$STAGE/image"
rm -rf "$IMAGE_ROOT" "$DMG"
mkdir -p "$IMAGE_ROOT"
mv "$APP" "$IMAGE_ROOT/ImageSearch.app"
ln -s /Applications "$IMAGE_ROOT/Applications"
hdiutil create -volname "ImageSearch $VERSION" -srcfolder "$IMAGE_ROOT" -fs HFS+ \
  -format ULMO -ov "$DMG" >/dev/null
mv "$IMAGE_ROOT/ImageSearch.app" "$APP"
rm -rf "$IMAGE_ROOT"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "NOTARY_PROFILE needs CODESIGN_IDENTITY: Apple only notarises Developer ID builds." >&2
    exit 1
  fi
  step "Notarising"
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

printf '\nBuilt %s\n' "$DMG"
printf '  app      %s\n' "$(du -sh "$APP" | cut -f1)"
printf '  image    %s\n' "$(du -sh "$DMG" | cut -f1)"
printf '  sha256   %s\n' "$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
