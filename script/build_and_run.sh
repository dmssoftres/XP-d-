#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="XPd"
BUNDLE_NAME="XP[d]"
BUNDLE_ID="com.dmssoftres.xpd"
APP_VERSION="0.2.1"
APP_BUILD="26"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$BUNDLE_NAME.app"
INFO_PLIST="$APP/Contents/Info.plist"

open_app() {
  /usr/bin/open "$APP"
}

stop_app() {
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in {1..50}; do
    if ! pgrep -x "$APP_NAME" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out waiting for XP[d] to quit." >&2
  return 1
}

require_built_app() {
  if [[ ! -x "$APP/Contents/MacOS/$APP_NAME" ]]; then
    echo "XP[d] has not been built yet; run $0 first." >&2
    exit 1
  fi
}

case "$MODE" in
  --relaunch|relaunch)
    require_built_app
    stop_app
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "XP[d] relaunched without changing its code signature."
    exit 0
    ;;
  --reset-input-monitoring|reset-input-monitoring)
    require_built_app
    stop_app
    /usr/bin/tccutil reset ListenEvent "$BUNDLE_ID"
    /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent'
    open_app
    echo "Reset XP[d]'s stale Input Monitoring record. Enable XP[d], then use --relaunch."
    exit 0
    ;;
  --reset-permissions|reset-permissions)
    require_built_app
    stop_app
    /usr/bin/tccutil reset Accessibility "$BUNDLE_ID"
    /usr/bin/tccutil reset ListenEvent "$BUNDLE_ID"
    /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
    open_app
    echo "Reset XP[d]'s Accessibility and Input Monitoring records. Approve XP[d] in Accessibility, then use --relaunch."
    exit 0
    ;;
esac

stop_app

cd "$ROOT"
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>$BUNDLE_NAME</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>XP[d] reads input from your connected Shortcut Remote so its controls can be mapped.</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>XP[d] reads the connected Shortcut Remote's verified battery level.</string>
</dict>
</plist>
PLIST

# Keep the app's designated requirement stable across local ad-hoc rebuilds.
# Without this, codesign falls back to a cdhash requirement and macOS treats
# every build as a different app for Accessibility and Input Monitoring.
/usr/bin/codesign \
  --force \
  --sign - \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP"

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "XP[d] launched successfully."
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--relaunch|--reset-permissions|--reset-input-monitoring]" >&2
    exit 2
    ;;
esac
