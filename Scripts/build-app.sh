#!/usr/bin/env bash
# Builds CodeScope in release mode and wraps it into a double-clickable CodeScope.app bundle.
#
# Usage:  Scripts/build-app.sh [--debug]
# Output: build/CodeScope.app
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="debug"
fi

echo "▸ Building CodeScope ($CONFIG)…"
swift build -c "$CONFIG" --product CodeScope

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="build/CodeScope.app"
CONTENTS="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/CodeScope" "$CONTENTS/MacOS/CodeScope"
cp Resources/Info.plist "$CONTENTS/Info.plist"
echo -n "APPL????" > "$CONTENTS/PkgInfo"

# Generate an app icon from the SF Symbol-free fallback if iconutil is available and no icon exists.
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" >/dev/null 2>&1 || true
fi

# Ad-hoc sign so the app launches without Gatekeeper complaints about an unsigned binary
# and so the Keychain item is stable across rebuilds.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || echo "⚠︎ codesign unavailable; the app will still run from Finder (right-click → Open)."

echo "✓ Built $APP_DIR"
echo "  Run it with:  open $APP_DIR"
