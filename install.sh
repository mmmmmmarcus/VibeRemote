#!/bin/bash

# Builds VibeRemote and installs it over /Applications/VibeRemote.app.
#
# Why this exists: macOS keys Accessibility / Input Monitoring / Bluetooth grants to the
# app's code signature. An ad-hoc signature ("-") is different on every build, so every
# rebuild revokes those grants and the app has to be approved again by hand. Signing with a
# stable Developer ID identity keeps one designated requirement for the life of the app, so
# the permissions are granted once and survive every reinstall.
#
#   ./install.sh
#
# Override the identity when building on another machine:
#   CODESIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID)" ./install.sh
#
# ARCHS="$(uname -m)" ./install.sh builds host-only, which is roughly twice as fast while
# iterating. The default is a universal build.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="VibeRemote"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_BUNDLE}"

# SMAppService resolves the privileged helper's launchd plist relative to the app bundle and
# only trusts /Applications; from ~/Applications registration fails with .notFound.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' \
            | head -n 1
    )"
fi

if [ -n "$CODESIGN_IDENTITY" ]; then
    echo "Signing with: $CODESIGN_IDENTITY"
    SIGNING_MODE=developer CODESIGN_IDENTITY="$CODESIGN_IDENTITY" ./create_app_bundle.sh
else
    # No stable identity available. The build still works, but macOS will ask for the three
    # privacy approvals again after every rebuild.
    echo "Warning: no Developer ID identity found; falling back to an ad-hoc signature."
    echo "         macOS will require re-approving Accessibility / Input Monitoring /"
    echo "         Bluetooth after each build. Install a Developer ID certificate, or pass"
    echo "         CODESIGN_IDENTITY=... to reuse one."
    ./create_app_bundle.sh
fi

echo "Installing to $INSTALL_PATH"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
# Give the menu-bar app a moment to release its status item and HID interfaces.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.3
done
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

rm -rf "$INSTALL_PATH"
ditto "$APP_BUNDLE" "$INSTALL_PATH"
open "$INSTALL_PATH"

echo
echo "Installed and launched: $INSTALL_PATH"
codesign -dv --verbose=2 "$INSTALL_PATH" 2>&1 | sed -n 's/^\(Authority\|Identifier\|TeamIdentifier\)=/  &/p'
