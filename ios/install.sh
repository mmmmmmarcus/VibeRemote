#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -ne 1 ]]; then
  echo 'Usage: ./install.sh DEVICE_UDID' >&2
  exit 1
fi
./build.sh
xcrun devicectl device install app --device "$1" build/vvhisper.app
xcrun devicectl device process launch --device "$1" com.vvhisper.ios
