#!/bin/bash
# Builds a self-contained Curio.app and wraps it in a disk image that can
# be attached to a GitHub release.
#
#   bash scripts/build-dmg.sh
#
# Unlike build-app.sh, the result does not depend on this checkout: the app is
# one Swift binary plus the Core ML models listed in BUNDLE_MODELS, and it
# keeps its settings in ~/Library/Application Support/Curio. No Python.
#
# Optional environment:
#   APP_VERSION          version to stamp (default: macos/VERSION)
#   BUNDLE_MODELS        models to ship inside the app, space separated
#                        (default: none; the app asks to download one on first
#                        launch from huggingface.co/ElectricGoal/curio-models)
#   MODELS_URL           another address serving models/coreml/ to download
#                        from (default: that Hugging Face repository)
#   CODESIGN_IDENTITY    "Developer ID Application: …" to sign for distribution
#                        (default: ad-hoc; Gatekeeper will warn on other Macs)
#   NOTARY_PROFILE       notarytool keychain profile; notarises and staples the
#                        disk image (needs CODESIGN_IDENTITY)
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$CURIO_PROJECT_ROOT"

VERSION="${APP_VERSION:-$(cat macos/VERSION)}"
ARCH="$(uname -m)"
STAGE="$CURIO_PROJECT_ROOT/dist/standalone"
APP="$STAGE/Curio.app"
RESOURCES="$APP/Contents/Resources"
DMG="$CURIO_PROJECT_ROOT/dist/Curio-$VERSION-$ARCH.dmg"
read -r -a MODELS <<<"${BUNDLE_MODELS-}"

step() { printf '\n==> %s\n' "$1"; }

if [[ "$ARCH" != "arm64" ]]; then
  echo "Curio only runs on Apple Silicon; build on an arm64 Mac." >&2
  exit 1
fi

step "Building the app ($VERSION)"
mkdir -p .cache/clang .cache/swift
export CLANG_MODULE_CACHE_PATH="$CURIO_PROJECT_ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CURIO_PROJECT_ROOT/.cache/swift"
swift build --package-path macos -c release
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"
cp macos/.build/release/Curio "$APP/Contents/MacOS/Curio"
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
  SELF_TEST_DATA="$(mktemp -d "$TMPDIR/curio-self-test.XXXXXX")"
  (cd / && env -i HOME="$HOME" PATH=/usr/bin:/bin CURIO_DATA_ROOT="$SELF_TEST_DATA" \
    "$APP/Contents/MacOS/Curio" --self-test | sed 's/^/  /')
  rm -rf "$SELF_TEST_DATA"
else
  echo "  skipped: this build carries no model; it downloads one on first launch"
fi

step "Creating the disk image"
IMAGE_ROOT="$STAGE/image"
rm -rf "$IMAGE_ROOT" "$DMG"
mkdir -p "$IMAGE_ROOT"
mv "$APP" "$IMAGE_ROOT/Curio.app"
ln -s /Applications "$IMAGE_ROOT/Applications"
hdiutil create -volname "Curio $VERSION" -srcfolder "$IMAGE_ROOT" -fs HFS+ \
  -format ULMO -ov "$DMG" >/dev/null
mv "$IMAGE_ROOT/Curio.app" "$APP"
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
