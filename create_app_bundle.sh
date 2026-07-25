#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="VibeRemote"
APP_BUNDLE="${APP_NAME}.app"
ENTITLEMENTS="${APP_NAME}.entitlements"
ICON_SOURCE="${APP_NAME}.icon"
ICON_PNG="${APP_NAME}AppIcon.png"
ICON_FILE="${APP_NAME}.icns"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.viberemote.app}"
APP_VERSION="${APP_VERSION:-0.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_MODE="${SIGNING_MODE:-local}"
INCLUDE_VOICE_HELPER="${INCLUDE_VOICE_HELPER:-1}"

case "$SIGNING_MODE" in
    local)
        signing_identity="-"
        ;;
    developer|release)
        signing_identity="${CODESIGN_IDENTITY:-}"
        if [ -z "$signing_identity" ]; then
            echo "Error: CODESIGN_IDENTITY is required for SIGNING_MODE=$SIGNING_MODE."
            exit 1
        fi
        if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$signing_identity"; then
            echo "Error: signing identity is not available: $signing_identity"
            exit 1
        fi
        ;;
    *)
        echo "Error: SIGNING_MODE must be local, developer, or release."
        exit 1
        ;;
esac

if [ "$SIGNING_MODE" = "release" ] && [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "Error: NOTARY_PROFILE is required for release signing."
    exit 1
fi
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Error: required entitlements file is missing: $ENTITLEMENTS"
    exit 1
fi

./build.sh

echo "Creating app bundle: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "$APP_NAME" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

icon_png=""
if [ -f "$ICON_PNG" ]; then
    icon_png="$ICON_PNG"
elif [ -f "${ICON_SOURCE}/Assets/remote 2.png" ]; then
    icon_png="${ICON_SOURCE}/Assets/remote 2.png"
fi

if [ -n "$icon_png" ]; then
    echo "Generating app icon from: $icon_png"
    iconset="${APP_BUNDLE}/Contents/Resources/${APP_NAME}.iconset"
    mkdir -p "$iconset"
    sips -z 16 16 "$icon_png" --out "${iconset}/icon_16x16.png" >/dev/null
    sips -z 32 32 "$icon_png" --out "${iconset}/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$icon_png" --out "${iconset}/icon_32x32.png" >/dev/null
    sips -z 64 64 "$icon_png" --out "${iconset}/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$icon_png" --out "${iconset}/icon_128x128.png" >/dev/null
    sips -z 256 256 "$icon_png" --out "${iconset}/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$icon_png" --out "${iconset}/icon_256x256.png" >/dev/null
    sips -z 512 512 "$icon_png" --out "${iconset}/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$icon_png" --out "${iconset}/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$icon_png" --out "${iconset}/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$iconset" -o "${APP_BUNDLE}/Contents/Resources/$ICON_FILE"
    rm -rf "$iconset"
else
    echo "Error: no app icon source was found."
    exit 1
fi

voice_resources="${APP_BUNDLE}/Contents/Resources/SiriRemoteVoiceControl"
voice_bridge_binary="VibeRemoteVoiceBridge"
if [ "$INCLUDE_VOICE_HELPER" = "1" ] && [ -x "$voice_bridge_binary" ]; then
    mkdir -p "$voice_resources"
    cp "$voice_bridge_binary" "$voice_resources/"
    chmod 755 "$voice_resources/$voice_bridge_binary"
elif [ "$INCLUDE_VOICE_HELPER" = "1" ]; then
    echo "Error: the microphone bridge helper was not built."
    exit 1
else
    echo "Voice helper excluded from this bundle."
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_IDENTIFIER</string>
	<key>CFBundleIconFile</key>
	<string>$ICON_FILE</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>VibeRemote uses Bluetooth to receive Siri Remote microphone audio and read battery state.</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>VibeRemote uses Bluetooth to receive Siri Remote microphone audio and read battery state.</string>
</dict>
</plist>
EOF

plutil -lint "${APP_BUNDLE}/Contents/Info.plist" "$ENTITLEMENTS"
chmod 755 "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

timestamp_args=(--timestamp=none)
if [ "$signing_identity" != "-" ]; then
    timestamp_args=(--timestamp)
fi

helper="${voice_resources}/VibeRemoteVoiceBridge"
if [ -f "$helper" ]; then
    if [ "$signing_identity" != "-" ]; then
        codesign --force --options runtime "${timestamp_args[@]}" --sign "$signing_identity" "$helper"
    else
        codesign --force "${timestamp_args[@]}" --sign "$signing_identity" "$helper"
    fi
fi

codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "${timestamp_args[@]}" \
    --sign "$signing_identity" \
    "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [ "$SIGNING_MODE" = "release" ]; then
    archive_path=".build/${APP_NAME}-notarization.zip"
    rm -f "$archive_path"
    ditto -c -k --keepParent "$APP_BUNDLE" "$archive_path"
    xcrun notarytool submit "$archive_path" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
    rm -f "$archive_path"
elif [ "$SIGNING_MODE" = "developer" ]; then
    echo "Developer-signed build created without notarization. Use SIGNING_MODE=release for distribution."
fi

echo "App bundle created: $ROOT_DIR/$APP_BUNDLE"
echo "Run it with: open '$ROOT_DIR/$APP_BUNDLE'"
