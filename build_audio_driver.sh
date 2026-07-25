#!/bin/bash

# Builds the VibeRemote virtual audio driver.
#
# The driver is BlackHole (github.com/ExistentialAudio/BlackHole, GPL-3.0) rebuilt with
# VibeRemote branding so the user only ever sees one product: the CoreAudio device, driver,
# and manufacturer are all named "VibeRemote". BlackHole exposes these as compile-time
# constants; the only source edit is routing the box's hardcoded manufacturer string
# through kManufacturer_Name so no upstream branding leaks into the binary.
#
# GPL-3.0 compliance: the driver we ship is a modified BlackHole build. See
# THIRD_PARTY_NOTICES.md for the upstream source, license, and the modifications applied.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

DRIVER_NAME="VibeRemoteAudio"
DEVICE_NAME="VibeRemote"
BUNDLE_ID="com.viberemote.audio"
CHANNELS="${CHANNELS:-2}"
BLACKHOLE_REF="${BLACKHOLE_REF:-master}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.build/audio-driver}"
OUTPUT_DIR="$ROOT_DIR/AudioDriver"
SIGNING_MODE="${SIGNING_MODE:-local}"

case "$SIGNING_MODE" in
    local)
        signing_identity="-"
        ;;
    developer|release)
        signing_identity="${CODESIGN_IDENTITY:-}"
        if [ -z "$signing_identity" ]; then
            echo "Error: CODESIGN_IDENTITY is required for SIGNING_MODE=$SIGNING_MODE." >&2
            exit 1
        fi
        ;;
    *)
        echo "Error: SIGNING_MODE must be local, developer, or release." >&2
        exit 1
        ;;
esac

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Error: xcodebuild not found. Install Xcode." >&2
    exit 1
fi

echo "Preparing BlackHole source ($BLACKHOLE_REF)"
mkdir -p "$WORK_DIR"
src="$WORK_DIR/BlackHole"
if [ -d "$src/.git" ]; then
    git -C "$src" fetch --depth 1 origin "$BLACKHOLE_REF"
    git -C "$src" checkout -f FETCH_HEAD
else
    rm -rf "$src"
    git clone --depth 1 --branch "$BLACKHOLE_REF" \
        https://github.com/ExistentialAudio/BlackHole.git "$src"
fi

# The device manufacturer already honors kManufacturer_Name; the box manufacturer is
# hardcoded upstream. Route it through the same constant so nothing says "Existential".
driver_source="$src/BlackHole/BlackHole.c"
if grep -q 'CFSTR("Existential Audio Inc.")' "$driver_source"; then
    /usr/bin/sed -i '' 's|CFSTR("Existential Audio Inc.")|CFSTR(kManufacturer_Name)|g' "$driver_source"
    echo "Patched hardcoded manufacturer string"
fi

# Ship our own icon. BlackHole references its icon by a fixed filename in the Xcode
# project, so replace the file contents rather than rewiring the project.
icon_png="$ROOT_DIR/VibeRemoteAppIcon.png"
if [ -f "$icon_png" ]; then
    iconset="$WORK_DIR/VibeRemote.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "$icon_png" \
            --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$src/BlackHole/BlackHole.icns"
    echo "Replaced driver icon with the VibeRemote icon"
fi

echo "Building $DRIVER_NAME.driver (device \"$DEVICE_NAME\", ${CHANNELS}ch)"
rm -rf "$WORK_DIR/DerivedData"
build_args=(
    -project "$src/BlackHole.xcodeproj"
    -scheme BlackHole
    -configuration Release
    -derivedDataPath "$WORK_DIR/DerivedData"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
    PRODUCT_NAME="$DRIVER_NAME"
    GCC_PREPROCESSOR_DEFINITIONS="\$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\\\"$DEVICE_NAME\\\" kPlugIn_BundleID=\\\"$BUNDLE_ID\\\" kHas_Driver_Name_Format=false kDevice_Name=\\\"$DEVICE_NAME\\\" kDevice2_Name=\\\"$DEVICE_NAME\\ Mirror\\\" kManufacturer_Name=\\\"$DEVICE_NAME\\\" kNumber_Of_Channels=$CHANNELS"
)
if [ "$signing_identity" = "-" ]; then
    build_args+=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)
else
    build_args+=(CODE_SIGN_IDENTITY="$signing_identity" CODE_SIGN_STYLE=Manual)
    if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
        build_args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
    fi
fi
xcodebuild "${build_args[@]}" build >"$WORK_DIR/xcodebuild.log" 2>&1 || {
    echo "Error: driver build failed. Tail of $WORK_DIR/xcodebuild.log:" >&2
    tail -20 "$WORK_DIR/xcodebuild.log" >&2
    exit 1
}

built="$WORK_DIR/DerivedData/Build/Products/Release/$DRIVER_NAME.driver"
if [ ! -d "$built" ]; then
    echo "Error: expected driver at $built" >&2
    exit 1
fi

if strings "$built/Contents/MacOS/$DRIVER_NAME" | grep -qi existential; then
    echo "Error: upstream branding leaked into the built driver." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/$DRIVER_NAME.driver"
cp -R "$built" "$OUTPUT_DIR/"

if [ "$signing_identity" != "-" ]; then
    codesign --force --timestamp --sign "$signing_identity" "$OUTPUT_DIR/$DRIVER_NAME.driver"
fi
codesign --verify --strict --verbose=1 "$OUTPUT_DIR/$DRIVER_NAME.driver" 2>&1 | tail -1

echo "Built $OUTPUT_DIR/$DRIVER_NAME.driver"
