#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="VibeRemote"
VOICE_BRIDGE_NAME="VibeRemoteVoiceBridge"
HELPER_NAME="VibeRemoteHelper"
CONFIGURATION="${CONFIGURATION:-release}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-11.0}"
ARCHS="${ARCHS:-arm64 x86_64}"

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --show-sdk-path --sdk macosx >/dev/null 2>&1; then
    echo "Error: macOS SDK not found. Install Xcode Command Line Tools with:"
    echo "  xcode-select --install"
    exit 1
fi

read -r -a architectures <<< "$ARCHS"
if [ "${#architectures[@]}" -eq 0 ]; then
    echo "Error: ARCHS must contain at least one architecture."
    exit 1
fi

echo "Building $APP_NAME ($CONFIGURATION) for: ${architectures[*]}"

app_binaries=()
voice_bridge_binaries=()
helper_binaries=()
for arch in "${architectures[@]}"; do
    case "$arch" in
        arm64|x86_64) ;;
        *)
            echo "Error: unsupported architecture '$arch' (expected arm64 or x86_64)."
            exit 1
            ;;
    esac

    triple="${arch}-apple-macosx${MACOS_DEPLOYMENT_TARGET}"
    scratch_path=".build/${arch}"
    swift build \
        --configuration "$CONFIGURATION" \
        --triple "$triple" \
        --scratch-path "$scratch_path" \
        --product "$APP_NAME"
    swift build \
        --configuration "$CONFIGURATION" \
        --triple "$triple" \
        --scratch-path "$scratch_path" \
        --product "$VOICE_BRIDGE_NAME"
    swift build \
        --configuration "$CONFIGURATION" \
        --triple "$triple" \
        --scratch-path "$scratch_path" \
        --product "$HELPER_NAME"
    bin_path="$(swift build \
        --configuration "$CONFIGURATION" \
        --triple "$triple" \
        --scratch-path "$scratch_path" \
        --show-bin-path)"
    app_binary="$bin_path/$APP_NAME"
    voice_bridge_binary="$bin_path/$VOICE_BRIDGE_NAME"
    helper_binary="$bin_path/$HELPER_NAME"
    if [ ! -x "$app_binary" ]; then
        echo "Error: SwiftPM did not produce $app_binary"
        exit 1
    fi
    if [ ! -x "$voice_bridge_binary" ]; then
        echo "Error: SwiftPM did not produce $voice_bridge_binary"
        exit 1
    fi
    app_binaries+=("$app_binary")
    if [ ! -x "$helper_binary" ]; then
        echo "Error: SwiftPM did not produce $helper_binary"
        exit 1
    fi
    voice_bridge_binaries+=("$voice_bridge_binary")
    helper_binaries+=("$helper_binary")
done

if [ "${#app_binaries[@]}" -eq 1 ]; then
    cp "${app_binaries[0]}" "$APP_NAME"
    cp "${voice_bridge_binaries[0]}" "$VOICE_BRIDGE_NAME"
    cp "${helper_binaries[0]}" "$HELPER_NAME"
else
    xcrun lipo -create "${app_binaries[@]}" -output "$APP_NAME"
    xcrun lipo -create "${voice_bridge_binaries[@]}" -output "$VOICE_BRIDGE_NAME"
    xcrun lipo -create "${helper_binaries[@]}" -output "$HELPER_NAME"
fi

chmod +x "$APP_NAME" "$VOICE_BRIDGE_NAME" "$HELPER_NAME"
echo "Built $ROOT_DIR/$APP_NAME"
xcrun lipo -info "$APP_NAME"
echo "Built $ROOT_DIR/$VOICE_BRIDGE_NAME"
xcrun lipo -info "$VOICE_BRIDGE_NAME"
echo "Built $ROOT_DIR/$HELPER_NAME"
xcrun lipo -info "$HELPER_NAME"
