#!/bin/bash
# Usage: scripts/test.sh [Suite]
# Generates the Xcode project and runs the tests, optionally limited to one suite.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

xcodegen generate --quiet || exit $?

args=(-project Readme.xcodeproj -scheme Readme -destination 'platform=macOS' -derivedDataPath build/DerivedData)
if [ -n "$1" ]; then
  args+=("-only-testing:ReadmeTests/$1")
fi

xcodebuild test "${args[@]}" 2>&1 \
  | grep -E '^(/.*: (error|warning):|✔|✘|Test Suite .* (passed|failed)|\*\* )'
exit "${PIPESTATUS[0]}"
