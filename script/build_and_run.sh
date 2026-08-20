#!/bin/zsh
set -euo pipefail

APP_NAME="XPd"
BUNDLE_NAME="XP[d]"
BUNDLE_ID="com.dmssoftres.xpd"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$BUNDLE_NAME.app"
BINARY="$ROOT/.build/debug/$APP_NAME"

pkill -x "$APP_NAME" 2>/dev/null || true

cd "$ROOT"
swift build

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$BUNDLE_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/open -n "$APP"

if [[ "${1:-}" == "--verify" ]]; then
  sleep 1
  pgrep -x "$APP_NAME" >/dev/null
  echo "XP[d] launched successfully."
fi
