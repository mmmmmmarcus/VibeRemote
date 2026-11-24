#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
configuration=${IOS_BUILD_CONFIGURATION:-Debug}
case "$configuration" in Debug|Release) ;; *) echo "Unsupported iOS build configuration: $configuration" >&2; exit 1 ;; esac
python3 ../macos/scripts/prepare-private-credentials.py
python3 scripts/prepare-rime.py
python3 scripts/compile-rime.py
xcodegen generate
scratch=$(mktemp -d "${TMPDIR:-/tmp}/vvhisper-ios.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
xcodebuild -project vvhisperIOS.xcodeproj -scheme vvhisperIOS -configuration "$configuration" \
  -destination 'generic/platform=iOS' -derivedDataPath "$scratch" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build "$@"
output=build/vvhisper.app
if [[ "$configuration" == Release ]]; then output=build/release/vvhisper.app; fi
mkdir -p "$(dirname "$output")"
# Replace only this script's reproducible output, never an installed application.
rm -rf "$output"
ditto "$scratch/Build/Products/$configuration-iphoneos/vvhisper.app" "$output"
if [[ " $* " != *" CODE_SIGNING_ALLOWED=NO "* ]]; then
  codesign --verify --deep --strict "$output"
fi
