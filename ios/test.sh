#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
python3 scripts/prepare-rime.py
python3 scripts/compile-rime.py
xcodegen generate
scratch=$(mktemp -d "${TMPDIR:-/tmp}/vvhisper-ios-tests.XXXXXX")
trap 'rm -rf "$scratch"' EXIT INT TERM
destination="${IOS_TEST_DESTINATION:-}"
if [[ -z "$destination" ]]; then
  simulator_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[v["udid"] for k,vs in d["devices"].items() if "iOS-27" in k for v in vs if "iPhone" in v["name"]]; print(ids[0] if ids else "")')
  [[ -n "$simulator_id" ]] || { echo "Install an iOS 27 simulator or set IOS_TEST_DESTINATION." >&2; exit 1; }
  destination="platform=iOS Simulator,id=$simulator_id"
fi
xcodebuild -project vvhisperIOS.xcodeproj -scheme vvhisperIOS -configuration Debug \
  -destination "$destination" \
  -derivedDataPath "$scratch" CODE_SIGNING_ALLOWED=NO test
