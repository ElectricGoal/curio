#!/bin/bash
# Proves a disk image built by build-dmg.sh works on its own.
#
#   bash scripts/check-dmg.sh [path/to/Curio-x.y.z-arm64.dmg]
#
# Mounts the image, copies the app out the way a user would, and runs the
# app's self-test in a bare environment with a throwaway data folder: for each
# model inside the app it indexes a few generated images and searches them by
# description. Nothing from this checkout is on the path.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$CURIO_PROJECT_ROOT"

DMG="${1:-$(ls -t dist/Curio-*.dmg 2>/dev/null | head -1)}"
[[ -f "$DMG" ]] || { echo "No disk image found. Run scripts/build-dmg.sh first." >&2; exit 1; }
WORK="$(mktemp -d /tmp/curio-check.XXXXXX)"
MOUNT="$WORK/mount"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Mounting $(basename "$DMG")"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
[[ -L "$MOUNT/Applications" ]] || { echo "missing the Applications shortcut" >&2; exit 1; }
ditto "$MOUNT/Curio.app" "$WORK/Curio.app"
hdiutil detach "$MOUNT" -quiet
APP="$WORK/Curio.app"

echo "==> Verifying the signature"
codesign --verify --deep --strict "$APP"
if /usr/libexec/PlistBuddy -c 'Print :CurioProjectRoot' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "the bundle is linked to a source tree; it would not run elsewhere" >&2
  exit 1
fi

echo "==> Checking the app needs nothing that is not part of macOS"
if find "$APP" -name 'python*' -o -name '*.py' -o -name 'site-packages' | grep -q .; then
  echo "the bundle still contains Python" >&2
  exit 1
fi
LINKED="$(otool -L "$APP/Contents/MacOS/Curio" | tail -n +2 | awk '{print $1}')"
if OUTSIDE="$(grep -Ev '^(/System/Library/|/usr/lib/)' <<<"$LINKED")"; then
  printf 'the app links libraries a clean Mac does not have:\n%s\n' "$OUTSIDE" >&2
  exit 1
fi

if [[ ! -s "$APP/Contents/Resources/mlx.metallib" ]]; then
  echo "the app is missing MLX's GPU shaders (Contents/Resources/mlx.metallib)" >&2
  exit 1
fi

if [[ -d "$APP/Contents/Resources/models" ]]; then
  echo "==> Indexing and searching with the models inside the app"
  mkdir -p "$WORK/data"
  (cd / && env -i HOME="$HOME" PATH=/usr/bin:/bin CURIO_DATA_ROOT="$WORK/data" \
    "$APP/Contents/MacOS/Curio" --self-test | sed 's/^/  /')
else
  echo "==> No models inside the app (it downloads them); checking only that it can use the GPU"
  mkdir -p "$WORK/data"
  # Without a model the self-test stops after its GPU check; that line is what is wanted.
  OUTPUT="$(cd / && env -i HOME="$HOME" PATH=/usr/bin:/bin CURIO_DATA_ROOT="$WORK/data" \
    "$APP/Contents/MacOS/Curio" --self-test || true)"
  if ! grep -q "MLX computes on the GPU" <<<"$OUTPUT"; then
    printf 'the app could not use the GPU through MLX:\n%s\n' "$OUTPUT" >&2
    exit 1
  fi
fi

echo "==> Checking nothing was written into the app"
codesign --verify --deep --strict "$APP"
echo
echo "The disk image is self-contained and working."
