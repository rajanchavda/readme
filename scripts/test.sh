#!/bin/bash
# Usage: scripts/test.sh [Suite]
# Generates the Xcode project and runs the tests, optionally limited to one suite.
# Prints the failures and a summary, and fails if no tests ran (a misspelt suite name, say).
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

xcodegen generate --quiet || exit $?

args=(-project Readme.xcodeproj -scheme Readme -destination 'platform=macOS' -derivedDataPath build/DerivedData)
if [ -n "$1" ]; then
  args+=("-only-testing:ReadmeTests/$1")
fi

log=$(mktemp "${TMPDIR:-/tmp}/readme-test.XXXXXX") || exit 1
trap 'rm -f "$log"' EXIT

xcodebuild test "${args[@]}" > "$log" 2>&1
status=$?

grep -E '^([^[:space:]]+: )?(fatal )?error:|^/.*: (fatal )?(error|warning):|^✔|^✘|^Test Suite .* (passed|failed)|^\*\* |^Testing failed:|^The test runner' "$log"

# Swift Testing ends with "Test run with N tests ... passed|failed".
ran=$(sed -nE 's/^[^ ]* Test run with ([0-9]+) tests?.*/\1/p' "$log" | tail -1)
if [ "$status" -eq 0 ] && [ "${ran:-0}" -eq 0 ]; then
  echo "error: no tests ran${1:+ for suite '$1'}" >&2
  exit 1
fi
[ -n "$ran" ] && echo "Summary: $ran tests run, exit status $status"
exit "$status"
