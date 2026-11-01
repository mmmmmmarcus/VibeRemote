#!/bin/bash
# Remove reproducible repository-local caches; keep source, Git, app and driver outputs.
# Do not run concurrently with builds or tests.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf -- "$ROOT_DIR/.build"
echo "Removed build caches: $ROOT_DIR/.build"
