#!/bin/bash

# Builds vvhisper and installs it over /Applications/vvhisper.app.
#
# Why this exists: macOS keys Accessibility / Input Monitoring / Bluetooth grants to the
# app's code signature. An ad-hoc signature ("-") is different on every build, so every
# rebuild can require approval again. Keep a stable Developer ID requirement and check
# compatibility with the installed app before quitting it. A signing-team migration still
# requires a separate, one-time permissions migration; this installer refuses identity drift.
#
#   ./install.sh
#
# Override the identity when building on another machine:
#   CODESIGN_IDENTITY="Developer ID Application: Haolin Fei (Q9MD524YL5)" ./install.sh
#
# Builds Apple Silicon (arm64) only. Temporary compiler caches are removed on exit.
# Set KEEP_BUILD_CACHE=1 only for active incremental development.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="vvhisper"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_BUNDLE}"

# Pin the personal identity: never silently select another team or fall back to ad-hoc.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Haolin Fei (Q9MD524YL5)}"
echo "Signing with: $CODESIGN_IDENTITY"
SIGNING_MODE=developer CODESIGN_IDENTITY="$CODESIGN_IDENTITY" ./create_app_bundle.sh

REPLACER="$ROOT_DIR/scripts/replace-app-bundle.py"
# Stage on the destination volume and validate both identities before stopping the app.
STAGING_DIR="$(python3 "$REPLACER" prepare "$ROOT_DIR/$APP_BUNDLE" "$INSTALL_PATH")"
installation_complete=0
cleanup_install() {
    local status=$?
    if [ -n "$STAGING_DIR" ] && [ "$installation_complete" -eq 0 ]; then
        if python3 "$REPLACER" rollback "$STAGING_DIR" "$INSTALL_PATH"; then
            python3 "$REPLACER" discard "$STAGING_DIR" "$INSTALL_PATH" || true
        else
            echo "Recovery files preserved: $STAGING_DIR" >&2
        fi
    fi
    return "$status"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Installing to $INSTALL_PATH"
# Match only this installed executable. Never resolve by name/bundle ID or launch a
# development copy just to ask it to quit. The graceful quit releases HID/held keys.
installed_process_pattern='^/Applications/vvhisper[.]app/Contents/MacOS/vvhisper($| )'
if pgrep -f "$installed_process_pattern" >/dev/null 2>&1; then
    osascript -e 'with timeout of 5 seconds' \
        -e "tell application \"$INSTALL_PATH\" to quit" \
        -e 'end timeout' >/dev/null 2>&1 || true
fi
# Give the menu-bar app a moment to release its status item and HID interfaces.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$installed_process_pattern" >/dev/null 2>&1 || break
    sleep 0.3
done
while IFS= read -r app_pid; do
    [ -n "$app_pid" ] || continue
    # Recheck the PID's executable immediately before sending the fallback signal.
    if [ "$(ps -p "$app_pid" -o comm= 2>/dev/null)" = "$INSTALL_PATH/Contents/MacOS/$APP_NAME" ]; then
        kill -TERM "$app_pid" 2>/dev/null || true
    fi
done < <(pgrep -f "$installed_process_pattern" || true)
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$installed_process_pattern" >/dev/null 2>&1 || break
    sleep 0.3
done
if pgrep -f "$installed_process_pattern" >/dev/null 2>&1; then
    echo "Error: installed vvhisper did not quit; leaving its bundle intact." >&2
    exit 1
fi

python3 "$REPLACER" install "$STAGING_DIR" "$INSTALL_PATH"
open "$INSTALL_PATH"
# LaunchServices accepting the request does not mean the executable started. Retain
# the old bundle until the exact installed process is observed, with a bounded wait.
installed_app_is_running() {
    local candidate_pid
    while IFS= read -r candidate_pid; do
        [ -n "$candidate_pid" ] || continue
        if [ "$(ps -p "$candidate_pid" -o comm= 2>/dev/null)" = "$INSTALL_PATH/Contents/MacOS/$APP_NAME" ]; then
            return 0
        fi
    done < <(pgrep -f "$installed_process_pattern" || true)
    return 1
}
app_started=0
for ((launch_attempt = 0; launch_attempt < 25; launch_attempt++)); do
    if installed_app_is_running; then
        app_started=1
        break
    fi
    sleep 0.2
done
if [ "$app_started" -ne 1 ]; then
    echo "Error: installed vvhisper did not start within 5 seconds; restoring the previous bundle." >&2
    exit 1
fi
installation_complete=1
python3 "$REPLACER" finish "$STAGING_DIR" "$INSTALL_PATH"
STAGING_DIR=""

echo
echo "Installed and launched: $INSTALL_PATH"
codesign -dv --verbose=2 "$INSTALL_PATH" 2>&1 | sed -n 's/^\(Authority\|Identifier\|TeamIdentifier\)=/  &/p'
