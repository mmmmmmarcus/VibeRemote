#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="VibeRemote"
VOICE_BRIDGE_NAME="VibeRemoteVoiceBridge"
HELPER_NAME="VibeRemoteHelper"
CONFIGURATION="${CONFIGURATION:-release}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-27.0}"
# This application targets Apple Silicon only. Reject old universal overrides.
if [ "${ARCHS:-arm64}" != "arm64" ]; then
    echo "Error: VibeRemote supports arm64 only; remove the ARCHS override." >&2
    exit 1
fi
if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --show-sdk-path --sdk macosx >/dev/null 2>&1; then
    echo "Error: macOS SDK not found. Install Xcode Command Line Tools." >&2
    exit 1
fi

case "${KEEP_BUILD_CACHE:-0}" in
    0)
        scratch_path="$(mktemp -d "${TMPDIR:-/tmp}/viberemote-build.XXXXXX")"
        trap 'rm -rf -- "$scratch_path"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        ;;
    1) scratch_path="$ROOT_DIR/.build/swiftpm" ;;
    *) echo "Error: KEEP_BUILD_CACHE must be 0 or 1." >&2; exit 1 ;;
esac

echo "Building $APP_NAME ($CONFIGURATION) for arm64"
triple="arm64-apple-macosx${MACOS_DEPLOYMENT_TARGET}"
build_args=(--configuration "$CONFIGURATION" --triple "$triple" --scratch-path "$scratch_path")
for product in "$APP_NAME" "$VOICE_BRIDGE_NAME" "$HELPER_NAME"; do
    swift build "${build_args[@]}" --product "$product"
done
bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
for product in "$APP_NAME" "$VOICE_BRIDGE_NAME" "$HELPER_NAME"; do
    if [ ! -x "$bin_path/$product" ]; then
        echo "Error: SwiftPM did not produce $bin_path/$product" >&2
        exit 1
    fi
    cp "$bin_path/$product" "$ROOT_DIR/$product"
done

# The settings asset loader resolves this bundle inside the app's Resources directory.
# Keep only this small staged resource bundle for create_app_bundle.sh.
resource_bundle="$bin_path/VibeRemote_VibeRemote.bundle"
if [ ! -d "$resource_bundle" ]; then
    echo "Error: SwiftPM did not produce the settings resource bundle"
    exit 1
fi
# SwiftPM's native and Xcode build systems use different bundle layouts. Merging
# them leaves a stale Contents/Resources that NSBundle prefers over fresh flat files.
rm -rf "$ROOT_DIR/.build/VibeRemote_VibeRemote.bundle"
mkdir -p "$ROOT_DIR/.build"
ditto "$resource_bundle" "$ROOT_DIR/.build/VibeRemote_VibeRemote.bundle"

python3 scripts/stage-sparkle.py "$scratch_path" "$ROOT_DIR/.build/Sparkle.framework"

chmod +x "$APP_NAME" "$VOICE_BRIDGE_NAME" "$HELPER_NAME"
echo "Built $ROOT_DIR/$APP_NAME"
xcrun lipo -info "$APP_NAME"
echo "Built $ROOT_DIR/$VOICE_BRIDGE_NAME"
xcrun lipo -info "$VOICE_BRIDGE_NAME"
echo "Built $ROOT_DIR/$HELPER_NAME"
xcrun lipo -info "$HELPER_NAME"
