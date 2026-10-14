#!/bin/bash
# Build the Swift package, wrap it in a .app bundle (so macOS Automation permissions
# and the accessory activation policy work), install it into /Applications, then relaunch it.
# Set INSTALL_DIR to install somewhere else.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/NotchApp"
# Staged inside .build so Spotlight and Launchpad only ever see the installed copy.
STAGE=".build/Notch.app"
APP="$INSTALL_DIR/Notch.app"

echo "==> Packaging…"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BIN" "$STAGE/Contents/MacOS/NotchApp"
cp Info.plist "$STAGE/Contents/Info.plist"

# Sign so the bundle has a stable identity for TCC and Keychain prompts. Ad-hoc by default;
# set CODESIGN_IDENTITY to a certificate name so rebuilds don't re-prompt for Keychain access.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$STAGE" >/dev/null 2>&1 || true

echo "==> Installing to $APP…"
killall NotchApp >/dev/null 2>&1 || true
sleep 0.3
rm -rf "$APP"
ditto "$STAGE" "$APP"
# Builds from before the app was installed lived here; one copy is enough.
rm -rf "Notch.app"

echo "==> Launching…"
open "$APP"
echo "==> Launched. Hover the notch to expand it."
