#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="VibeRemote"
APP_BUNDLE="${APP_NAME}.app"
ENTITLEMENTS="${APP_NAME}.entitlements"
ICON_SOURCE="${APP_NAME}.icon"
ICON_INFO_PLIST="$ROOT_DIR/.build/app-icon-info.plist"
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

# Compile the complete Icon Composer document; rasterizing an individual layer loses
# its materials and appearances. actool also supplies the matching Info.plist keys.
if [ ! -f "${ICON_SOURCE}/icon.json" ]; then
    echo "Error: Icon Composer source is missing: $ICON_SOURCE"
    exit 1
fi
icon_developer_dir="${ICON_DEVELOPER_DIR:-${DEVELOPER_DIR:-$(xcode-select -p)}}"
if ! DEVELOPER_DIR="$icon_developer_dir" xcrun --find actool >/dev/null 2>&1; then
    # Swift may use a newer standalone CLT SDK while asset compilation needs full Xcode.
    if [ -z "${ICON_DEVELOPER_DIR:-}" ]; then
        icon_developer_dir="$(env -u DEVELOPER_DIR xcode-select -p)"
    fi
fi
if ! DEVELOPER_DIR="$icon_developer_dir" xcrun --find actool >/dev/null 2>&1; then
    echo "Error: Icon Composer compilation requires full Xcode. Set ICON_DEVELOPER_DIR to its Contents/Developer directory."
    exit 1
fi

./build.sh

echo "Creating app bundle: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "$APP_NAME" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"
ditto ".build/VibeRemote_VibeRemote.bundle" "${APP_BUNDLE}/Contents/Resources/VibeRemote_VibeRemote.bundle"

echo "Compiling Icon Composer app icon: $ICON_SOURCE"
DEVELOPER_DIR="$icon_developer_dir" xcrun actool "$ICON_SOURCE" \
    --compile "${APP_BUNDLE}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 27.0 \
    --app-icon "$APP_NAME" \
    --output-partial-info-plist "$ICON_INFO_PLIST" \
    --output-format human-readable-text

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

# Bundle the privileged helper daemon and its launchd plist. SMAppService requires the
# executable in Contents/MacOS and the plist in Contents/Library/LaunchDaemons, with the
# plist's Label matching its filename and BundleProgram pointing at the executable.
helper_daemon_binary="VibeRemoteHelper"
helper_daemon_label="com.viberemote.helper"
if [ "${INCLUDE_PRIVILEGED_HELPER:-1}" = "1" ] && [ -x "$helper_daemon_binary" ]; then
    cp "$helper_daemon_binary" "${APP_BUNDLE}/Contents/MacOS/$helper_daemon_binary"
    chmod 755 "${APP_BUNDLE}/Contents/MacOS/$helper_daemon_binary"
    mkdir -p "${APP_BUNDLE}/Contents/Library/LaunchDaemons"
    cat > "${APP_BUNDLE}/Contents/Library/LaunchDaemons/${helper_daemon_label}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${helper_daemon_label}</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/${helper_daemon_binary}</string>
	<key>MachServices</key>
	<dict>
		<key>${helper_daemon_label}</key>
		<true/>
	</dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>${BUNDLE_IDENTIFIER}</string>
	</array>
	<key>StandardOutPath</key>
	<string>/var/log/viberemote-helper.log</string>
	<key>StandardErrorPath</key>
	<string>/var/log/viberemote-helper.log</string>
</dict>
</plist>
PLIST
    plutil -lint "${APP_BUNDLE}/Contents/Library/LaunchDaemons/${helper_daemon_label}.plist"
    echo "Bundled privileged helper: $helper_daemon_binary"
elif [ "${INCLUDE_PRIVILEGED_HELPER:-1}" = "1" ]; then
    echo "Note: $helper_daemon_binary not built; the app will fall back to admin prompts."
fi

# Personal builds may embed an installed Apple-signed PacketLogger, unmodified.
# Release distribution requires a separately reviewed redistribution policy.
packetlogger_source="${PACKETLOGGER_APP_SOURCE:-/Applications/Additional Tools for Xcode/Hardware/PacketLogger.app}"
if [ "${INCLUDE_PACKETLOGGER:-1}" = "1" ] && [ -d "$packetlogger_source" ]; then
    if [ "$SIGNING_MODE" = "release" ] && [ "${INCLUDE_PACKETLOGGER:-}" != "1" ]; then
        echo "Release builds omit PacketLogger unless INCLUDE_PACKETLOGGER=1 is explicitly set."
    else
        codesign --verify --deep --strict -R='identifier "com.apple.PacketLogger" and anchor apple' "$packetlogger_source"
        ditto "$packetlogger_source" "${APP_BUNDLE}/Contents/Resources/PacketLogger.app"
        echo "Bundled original Apple-signed PacketLogger"
    fi
fi

# Bundle the VibeRemote virtual audio driver so the app can install it itself. Build it
# with ./build_audio_driver.sh; bundles without it fall back to an existing BlackHole or
# Soundflower device and hide the in-app install action.
audio_driver="AudioDriver/VibeRemoteAudio.driver"
if [ "${INCLUDE_AUDIO_DRIVER:-1}" = "1" ] && [ -d "$audio_driver" ]; then
    cp -R "$audio_driver" "${APP_BUNDLE}/Contents/Resources/"
    echo "Bundled audio driver: $audio_driver"
elif [ "${INCLUDE_AUDIO_DRIVER:-1}" = "1" ]; then
    echo "Note: $audio_driver not found; run ./build_audio_driver.sh to bundle it."
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
	<string>27.0</string>
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

/usr/libexec/PlistBuddy -c "Merge $ICON_INFO_PLIST" "${APP_BUNDLE}/Contents/Info.plist"
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

# Nested code must be signed before the enclosing app, or the outer signature is invalid.
bundled_driver="${APP_BUNDLE}/Contents/Resources/VibeRemoteAudio.driver"
if [ -d "$bundled_driver" ]; then
    codesign --force "${timestamp_args[@]}" --sign "$signing_identity" "$bundled_driver"
fi

bundled_helper="${APP_BUNDLE}/Contents/MacOS/VibeRemoteHelper"
if [ -f "$bundled_helper" ]; then
    codesign --force --options runtime "${timestamp_args[@]}" \
        --identifier "com.viberemote.helper" \
        --sign "$signing_identity" "$bundled_helper"
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
