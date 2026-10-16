#!/usr/bin/env bash
# Build, test and scan before committing or opening a PR.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
swift test
scripts/secret-scan.sh
echo "All checks passed."
