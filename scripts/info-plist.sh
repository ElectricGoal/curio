#!/bin/bash
# Writes an app bundle's Info.plist.
#
#   info-plist.sh APP VERSION [--project-root ROOT] [--models-url URL]
#
# --project-root   a development build: the app keeps its models and settings
#                  in that checkout instead of Application Support
# --models-url     where the app may download models it does not carry
set -euo pipefail
APP="$1"
VERSION="$2"
shift 2
PLIST="$APP/Contents/Info.plist"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "info-plist.sh: '$VERSION' is not a version like 1.2.3" >&2
  exit 1
fi
cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ImageSearch</string>
  <key>CFBundleDisplayName</key><string>ImageSearch</string>
  <key>CFBundleIdentifier</key><string>local.imgsearch.desktop</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>ImageSearch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <!-- Lets folders be dropped on the Dock icon or opened with "open -a". -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
# plutil escapes the values, so paths and addresses with & or < are safe.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) plutil -insert ImageSearchProjectRoot -string "$2" "$PLIST" ;;
    --models-url) plutil -insert ImageSearchModelsURL -string "$2" "$PLIST" ;;
    *) echo "info-plist.sh: unknown option $1" >&2; exit 1 ;;
  esac
  shift 2
done
plutil -lint "$PLIST" >/dev/null
