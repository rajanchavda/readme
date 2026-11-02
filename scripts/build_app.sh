#!/bin/bash
# Usage: scripts/build_app.sh
# Builds build/Readme.app in Release, ad-hoc signed and sandboxed.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

xcodegen generate --quiet || exit $?

derived=build/DerivedData
xcodebuild build -project Readme.xcodeproj -scheme Readme -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" 2>&1 \
  | grep -E '^([^[:space:]]+: )?(fatal )?error:|^/.*: (fatal )?(error|warning):|^\*\* '
status=${PIPESTATUS[0]}
[ "$status" -eq 0 ] || exit "$status"

rm -rf build/Readme.app
ditto "$derived/Build/Products/Release/Readme.app" build/Readme.app || exit $?

# Fails the build rather than hand over an app that isn't what this script says it is.
codesign --verify --strict build/Readme.app || exit $?
codesign -d --entitlements - --xml build/Readme.app 2>/dev/null \
  | plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - - | grep -qx true || {
  echo "build/Readme.app is not sandboxed" >&2
  exit 1
}
[ "$(lipo -archs build/Readme.app/Contents/MacOS/Readme)" = "arm64" ] || {
  echo "build/Readme.app is not arm64 only" >&2
  exit 1
}
echo "Built build/Readme.app"
