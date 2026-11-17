#!/bin/bash
# Installs Curio into /Applications without Finder's drag-and-drop, which
# macOS 27 refuses for apps not signed with an Apple Developer ID.
#
#   bash install.sh                       # the latest release from GitHub
#   bash install.sh Curio-0.0.2-arm64.dmg # a disk image you already have
#   curl -fsSL https://raw.githubusercontent.com/ElectricGoal/curio/main/scripts/install.sh | bash
#
# Replaces an existing /Applications/Curio.app; your settings, downloaded
# models and folder indexes are kept. CURIO_APPLICATIONS installs elsewhere.
set -euo pipefail

REPO="ElectricGoal/curio"
DESTINATION="${CURIO_APPLICATIONS:-/Applications}"
APP="$DESTINATION/Curio.app"

fail() { echo "install.sh: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "Curio runs on macOS only."
[[ "$(uname -m)" == arm64 ]] || fail "Curio needs an Apple Silicon Mac."
[[ -w "$DESTINATION" ]] || fail "cannot write to $DESTINATION; run as an administrator, or set CURIO_APPLICATIONS."

work="$(mktemp -d "${TMPDIR:-/tmp}/curio-install.XXXXXX")"
mount="$work/volume"
cleanup() {
  hdiutil detach "$mount" -quiet 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

if [[ $# -ge 1 ]]; then
  image="$1"
  [[ -f "$image" ]] || fail "no such disk image: $image"
else
  echo "Finding the latest release of Curio…"
  status="$(curl -sSL -o "$work/release.json" -w '%{http_code}' \
    "https://api.github.com/repos/$REPO/releases/latest")" \
    || fail "could not reach GitHub; check your internet connection."
  [[ "$status" != 404 ]] || fail "no release of Curio has been published yet; see https://github.com/$REPO/releases"
  [[ "$status" == 200 ]] || fail "GitHub answered $status; try again later."
  url="$(grep -o '"browser_download_url": *"[^"]*/Curio-[^"]*-arm64\.dmg"' "$work/release.json" \
    | head -1 | sed 's/.*"\(https[^"]*\)"/\1/' || true)"
  [[ -n "$url" ]] || fail "the latest release has no Curio disk image; download one from https://github.com/$REPO/releases"
  image="$work/${url##*/}"
  echo "Downloading ${url##*/}…"
  curl -fL --progress-bar -o "$image" "$url" || fail "the download did not finish."
fi

# A private mount point: no Finder window, and no guessing the volume's name.
mkdir "$mount"
hdiutil attach "$image" -nobrowse -readonly -noautoopen -mountpoint "$mount" -quiet \
  || fail "could not open $image; it may be damaged, so download it again."
[[ -d "$mount/Curio.app" ]] || fail "$image does not contain Curio.app."

if pgrep -x Curio >/dev/null; then
  echo "Quitting Curio…"
  osascript -e 'quit app "Curio"' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x Curio >/dev/null || break; sleep 0.5; done
  if pgrep -x Curio >/dev/null; then fail "Curio is still running; quit it and try again."; fi
fi

echo "Installing to ${APP}…"
# Copied beside the old app, then swapped in, so a failed copy leaves it intact.
rm -rf "$DESTINATION/.Curio.app.installing"  # left by an interrupted install
ditto "$mount/Curio.app" "$DESTINATION/.Curio.app.installing"
rm -rf "$APP"
mv "$DESTINATION/.Curio.app.installing" "$APP"
# The "downloaded from the internet" mark is what makes macOS refuse to open it.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
echo "Installed Curio $version."
if [[ "${CURIO_NO_OPEN:-}" != 1 ]]; then open "$APP"; fi
