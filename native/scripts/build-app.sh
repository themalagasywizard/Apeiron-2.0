#!/usr/bin/env bash
# Builds a release Apeiron.app bundle from the SwiftPM package (macOS only).
#   scripts/build-app.sh            -> build/Apeiron.app and build/Apeiron.zip
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT=build
APP="$OUT/Apeiron.app"

swift build -c release --product Apeiron
swift build -c release --product apeiron
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Apeiron" "$APP/Contents/MacOS/Apeiron"
# Ship the terminal client inside the bundle too.
cp "$BIN/apeiron" "$APP/Contents/Resources/apeiron"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Apeiron</string>
  <key>CFBundleDisplayName</key><string>Apeiron</string>
  <key>CFBundleIdentifier</key><string>app.apeiron.desktop</string>
  <key>CFBundleExecutable</key><string>Apeiron</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
(cd "$OUT" && rm -f Apeiron.zip && ditto -c -k --keepParent Apeiron.app Apeiron.zip)
echo "Built $APP"
