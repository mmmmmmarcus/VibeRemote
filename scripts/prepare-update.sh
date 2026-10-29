#!/bin/bash
# Prepare a notarized, Ed25519-signed update locally. Never publishes or pushes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
APP_PATH="${1:-$ROOT_DIR/VibeRemote.app}"
OUTPUT_DIR="${2:-$ROOT_DIR/Release/artifacts}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")
# Never ship an ad-hoc build or silently prepare an unnotarized release.
codesign --verify --deep --strict "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute "$APP_PATH"
python3 scripts/validate-update-bundle.py "$APP_PATH"
TOOLS="$ROOT_DIR/.build/swiftpm/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$TOOLS/generate_appcast" ]; then
    swift package --scratch-path .build/swiftpm resolve
fi
mkdir -p "$OUTPUT_DIR"
ARCHIVE="$OUTPUT_DIR/VibeRemote-$VERSION-$BUILD.zip"
if [ -e "$ARCHIVE" ]; then
    echo "Refusing to replace an existing release archive: $ARCHIVE" >&2
    exit 1
fi
# Isolate appcast input from corresponding-source archives and older releases.
STAGING=$(mktemp -d "$OUTPUT_DIR/.appcast.XXXXXX")
trap 'rm -rf -- "$STAGING"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$STAGING/$(basename "$ARCHIVE")"
"$TOOLS/generate_appcast" --account com.viberemote.sparkle \
    --download-url-prefix "https://github.com/mmmmmmarcus/VibeRemote/releases/download/v$VERSION/" \
    --maximum-deltas 0 "$STAGING"
python3 scripts/validate-appcast.py "$STAGING/appcast.xml"
mv "$STAGING/$(basename "$ARCHIVE")" "$ARCHIVE"
mv "$STAGING/appcast.xml" "$OUTPUT_DIR/appcast.xml"
echo "Prepared signed update in $OUTPUT_DIR. Review before publishing."
