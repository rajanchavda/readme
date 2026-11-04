#!/bin/bash
# Usage: scripts/check_release.sh
# Checks build/Readme.app and build/Readme.dmg are what can be handed out: sandboxed, arm64 only, for
# macOS 14, signed, with no debugging entitlement and no network server, and the notices for what's
# bundled. Prints each check and fails if any does.
cd "$(dirname "$0")/.." || exit 1

app=build/Readme.app
dmg=build/Readme.dmg
failures=0

pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
check() { # check "description" command...
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}

entitlements=$(mktemp "${TMPDIR:-/tmp}/readme-entitlements.XXXXXX") || exit 1
mount=$(mktemp -d "${TMPDIR:-/tmp}/readme-dmg.XXXXXX") || exit 1
cleanup() {
  hdiutil detach "$mount" -quiet >/dev/null 2>&1
  rm -f "$entitlements"
  rmdir "$mount" 2>/dev/null
}
trap cleanup EXIT

entitlement() { plutil -extract "$1" raw -o - "$entitlements" 2>/dev/null; }

if [ -d "$app" ]; then
  check "the app's signature is valid" codesign --verify --strict --deep "$app"
  codesign -d --entitlements - --xml "$app" >"$entitlements" 2>/dev/null
  [ "$(entitlement 'com\.apple\.security\.app-sandbox')" = true ] && pass "the sandbox is on" || fail "the sandbox is on"
  [ "$(entitlement 'com\.apple\.security\.network\.client')" = true ] \
    && pass "network.client is on, for the web view" || fail "network.client is on, for the web view"
  [ -z "$(entitlement 'com\.apple\.security\.network\.server')" ] \
    && pass "no network.server" || fail "no network.server"
  network=$(grep -o 'com\.apple\.security\.network\.[a-z-]*' "$entitlements" | sort -u | tr '\n' ' ')
  [ "$network" = "com.apple.security.network.client " ] \
    && pass "network.client is the only network entitlement" \
    || fail "network.client is the only network entitlement (found: ${network:-none})"
  grep -q 'get-task-allow' "$entitlements" \
    && fail "no get-task-allow (debugging) entitlement" || pass "no get-task-allow (debugging) entitlement"
  [ "$(lipo -archs "$app/Contents/MacOS/Readme" 2>/dev/null)" = arm64 ] \
    && pass "the binary is arm64 only" || fail "the binary is arm64 only"
  [ "$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist" 2>/dev/null)" = 14.0 ] \
    && pass "LSMinimumSystemVersion is 14.0" || fail "LSMinimumSystemVersion is 14.0"
  [ "$(plutil -extract CFBundleIconName raw -o - "$app/Contents/Info.plist" 2>/dev/null)" = AppIcon ] \
    && [ -f "$app/Contents/Resources/Assets.car" ] \
    && pass "the app has its icon" || fail "the app has its icon"
else
  fail "$app exists (run scripts/package.sh)"
fi

grep -Eq '^[[:space:]]*ARCHS:[[:space:]]*arm64[[:space:]]*$' project.yml \
  && pass "project.yml pins ARCHS to arm64" || fail "project.yml pins ARCHS to arm64"

if [ -f THIRD_PARTY_NOTICES.md ]; then
  for name in foliate-js zip.js "EB Garamond" Literata Fraunces; do
    grep -q "$name" THIRD_PARTY_NOTICES.md && pass "the notices name $name" || fail "the notices name $name"
  done
else
  fail "THIRD_PARTY_NOTICES.md exists"
fi

check "docs/install.md exists" test -s docs/install.md

if [ -f "$dmg" ]; then
  check "the disk image is compressed (UDZO)" sh -c "hdiutil imageinfo '$dmg' | grep -q 'Format: UDZO'"
  if hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount" -quiet >/dev/null 2>&1; then
    check "the disk image holds Readme.app, validly signed" codesign --verify --strict --deep "$mount/Readme.app"
    [ -L "$mount/Applications" ] && [ "$(readlink "$mount/Applications")" = /Applications ] \
      && pass "the disk image has the Applications shortcut" || fail "the disk image has the Applications shortcut"
    volume=$(diskutil info "$mount" 2>/dev/null | sed -n 's/^ *Volume Name: *//p')
    [ "$volume" = Readme ] && pass "the volume is called Readme" || fail "the volume is called Readme (got '$volume')"
    hdiutil detach "$mount" -quiet >/dev/null 2>&1
  else
    fail "the disk image mounts"
  fi
else
  fail "$dmg exists (run scripts/package.sh)"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All release checks passed"
