#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
: "${IOS_TEST_DESTINATION:?Set an explicit simulator destination for touch tests.}"
[[ "$IOS_TEST_DESTINATION" == "platform=iOS Simulator,"* ]] || {
  echo "Touch tests configure keyboards on a dedicated simulator only." >&2
  exit 1
}
python3 scripts/prepare-rime.py
python3 scripts/compile-rime.py
xcodegen generate
scratch=$(mktemp -d "${TMPDIR:-/tmp}/vvhisper-ios-touches.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
xcodebuild -project vvhisperIOS.xcodeproj -scheme vvhisperKeyboardTouches -configuration Debug \
  -destination "$IOS_TEST_DESTINATION" -derivedDataPath "$scratch" CODE_SIGNING_ALLOWED=NO test "$@"
