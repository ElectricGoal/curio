#!/bin/bash
# Builds dist/Curio.app for use on this Mac.
#
# A development build: it is linked to this checkout, which is where it looks
# for models (models/coreml) and keeps its settings. For a self-contained app
# to give to others, use scripts/build-dmg.sh.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$CURIO_PROJECT_ROOT"
mkdir -p .cache/clang .cache/swift
export CLANG_MODULE_CACHE_PATH="$CURIO_PROJECT_ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CURIO_PROJECT_ROOT/.cache/swift"
swift build --package-path macos -c release
APP="$CURIO_PROJECT_ROOT/dist/Curio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp macos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp macos/.build/release/Curio "$APP/Contents/MacOS/Curio"
bash scripts/info-plist.sh "$APP" "${APP_VERSION:-$(cat macos/VERSION)}" \
  --project-root "$CURIO_PROJECT_ROOT"
codesign --force --deep --sign - "$APP"
printf '\nBuilt %s\n' "$APP"
if ! ls models/coreml/*/model.json >/dev/null 2>&1; then
  printf 'No models yet: run "bash scripts/convert-models.sh" before indexing.\n'
fi
