#!/bin/bash
# Usage: scripts/check_release.sh
# Checks build/Readme.app, and the copy of it inside build/Readme.dmg, are what can be handed out:
# signed, sandboxed, arm64 only, for macOS 14, with no debugging entitlement and no network server,
# with its icon and the notices for what's bundled. Checks the disk image itself, and the notices
# in the repo. Prints each check and fails if any does.
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
mounted=false

# A volume that's busy for a moment, as Spotlight or Quick Look can keep one, is asked again, then
# made to go.
detach() {
  $mounted || return 0
  for _ in 1 2 3; do
    hdiutil detach "$mount" -quiet >/dev/null 2>&1 && { mounted=false; return 0; }
    sleep 1
  done
  hdiutil detach "$mount" -force -quiet >/dev/null 2>&1 && { mounted=false; return 0; }
  return 1
}
cleanup() {
  detach
  rm -f "$entitlements"
  rmdir "$mount" 2>/dev/null
}
trap cleanup EXIT

entitlement() { plutil -extract "$1" raw -o - "$entitlements" 2>/dev/null; }

# Every check an app has to pass, for the app at $1, named $2 in what's printed.
check_app() {
  local app=$1 name=$2
  check "$name: the signature is valid" codesign --verify --strict --deep "$app"
  : >"$entitlements"
  codesign -d --entitlements - --xml "$app" >"$entitlements" 2>/dev/null
  # Without them, the checks for what mustn't be there would pass for nothing.
  if [ -s "$entitlements" ] && plutil -lint "$entitlements" >/dev/null 2>&1; then
    pass "$name: the entitlements can be read"
    [ "$(entitlement 'com\.apple\.security\.app-sandbox')" = true ] \
      && pass "$name: the sandbox is on" || fail "$name: the sandbox is on"
    [ "$(entitlement 'com\.apple\.security\.network\.client')" = true ] \
      && pass "$name: network.client is on, for the web view and update checks" || fail "$name: network.client is on, for the web view and update checks"
    [ -z "$(entitlement 'com\.apple\.security\.network\.server')" ] \
      && pass "$name: no network.server" || fail "$name: no network.server"
    local network
    network=$(grep -o 'com\.apple\.security\.network\.[a-z-]*' "$entitlements" | sort -u | tr '\n' ' ')
    [ "$network" = "com.apple.security.network.client " ] \
      && pass "$name: network.client is the only network entitlement" \
      || fail "$name: network.client is the only network entitlement (found: ${network:-none})"
    grep -q 'get-task-allow' "$entitlements" \
      && fail "$name: no get-task-allow (debugging) entitlement" \
      || pass "$name: no get-task-allow (debugging) entitlement"
  else
    fail "$name: the entitlements can be read"
  fi
  [ "$(lipo -archs "$app/Contents/MacOS/Readme" 2>/dev/null)" = arm64 ] \
    && pass "$name: the binary is arm64 only" || fail "$name: the binary is arm64 only"
  [ "$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist" 2>/dev/null)" = 14.0 ] \
    && pass "$name: LSMinimumSystemVersion is 14.0" || fail "$name: LSMinimumSystemVersion is 14.0"
  [ "$(plutil -extract CFBundleIconName raw -o - "$app/Contents/Info.plist" 2>/dev/null)" = AppIcon ] \
    && [ -f "$app/Contents/Resources/Assets.car" ] \
    && pass "$name: has its icon" || fail "$name: has its icon"
  cmp -s THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" \
    && pass "$name: carries the third-party notices" || fail "$name: carries the third-party notices"
}

if [ -d "$app" ]; then
  check_app "$app" "the app"
else
  fail "$app exists (run scripts/package.sh)"
fi

grep -Eq '^[[:space:]]*ARCHS:[[:space:]]*arm64[[:space:]]*$' project.yml \
  && pass "project.yml pins ARCHS to arm64" || fail "project.yml pins ARCHS to arm64"

if [ -f THIRD_PARTY_NOTICES.md ]; then
  for name in foliate-js zip.js "EB Garamond" Literata Fraunces; do
    grep -q "$name" THIRD_PARTY_NOTICES.md && pass "the notices name $name" || fail "the notices name $name"
  done
  # The licences' own words, not just the names: MIT, BSD 3-Clause, and the OFL once for each font.
  grep -q "Permission is hereby granted, free of charge" THIRD_PARTY_NOTICES.md \
    && pass "the notices hold the MIT licence" || fail "the notices hold the MIT licence"
  grep -q "Redistributions in binary form must reproduce the above copyright" THIRD_PARTY_NOTICES.md \
    && pass "the notices hold the BSD 3-Clause licence" || fail "the notices hold the BSD 3-Clause licence"
  [ "$(grep -c "SIL OPEN FONT LICENSE Version 1.1" THIRD_PARTY_NOTICES.md)" -ge 3 ] \
    && pass "the notices hold the font licence for each font" || fail "the notices hold the font licence for each font"
else
  fail "THIRD_PARTY_NOTICES.md exists"
fi

check "docs/install.md exists" test -s docs/install.md

if [ -f "$dmg" ]; then
  check "the disk image is compressed (UDZO)" sh -c "hdiutil imageinfo '$dmg' | grep -q 'Format: UDZO'"
  if hdiutil info 2>/dev/null | grep -q "$(cd build && pwd)/Readme.dmg"; then
    fail "the disk image isn't already attached (eject the Readme volume and run again)"
  elif hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount" -quiet >/dev/null 2>&1; then
    mounted=true
    if [ -d "$mount/Readme.app" ]; then
      check_app "$mount/Readme.app" "the app in the disk image"
    else
      fail "the disk image holds Readme.app"
    fi
    [ -L "$mount/Applications" ] && [ "$(readlink "$mount/Applications")" = /Applications ] \
      && pass "the disk image has the Applications shortcut" || fail "the disk image has the Applications shortcut"
    cmp -s THIRD_PARTY_NOTICES.md "$mount/THIRD_PARTY_NOTICES.md" \
      && pass "the disk image carries the third-party notices" || fail "the disk image carries the third-party notices"
    volume=$(diskutil info "$mount" 2>/dev/null | sed -n 's/^ *Volume Name: *//p')
    [ "$volume" = Readme ] && pass "the volume is called Readme" || fail "the volume is called Readme (got '$volume')"
    detach && pass "the disk image is ejected again" || fail "the disk image is ejected again"
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
