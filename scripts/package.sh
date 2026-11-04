#!/bin/bash
# Usage: scripts/package.sh
# Builds build/Readme.app from clean, then puts it in build/Readme.dmg beside a shortcut to
# Applications, for people to drag across, with the third-party notices. The disk image is
# compressed (UDZO) and its volume is called Readme.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

# Nothing from an earlier build carries over into what's handed out.
rm -rf build/DerivedData
scripts/build_app.sh || exit $?

stage=$(mktemp -d "${TMPDIR:-/tmp}/readme-dmg.XXXXXX") || exit 1
trap 'rm -rf "$stage"' EXIT
ditto build/Readme.app "$stage/Readme.app" || exit $?
ln -s /Applications "$stage/Applications" || exit $?
cp THIRD_PARTY_NOTICES.md "$stage/THIRD_PARTY_NOTICES.md" || exit $?

rm -f build/Readme.dmg
hdiutil create -volname Readme -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -ov -quiet build/Readme.dmg || exit $?
echo "Packaged build/Readme.dmg ($(du -h build/Readme.dmg | cut -f1 | tr -d ' '))"
