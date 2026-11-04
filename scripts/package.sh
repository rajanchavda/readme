#!/bin/bash
# Usage: scripts/package.sh
# Builds build/Readme.app, then puts it in build/Readme.dmg beside a shortcut to Applications, for
# people to drag across. The disk image is compressed (UDZO) and its volume is called Readme.
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

scripts/build_app.sh || exit $?

stage=$(mktemp -d "${TMPDIR:-/tmp}/readme-dmg.XXXXXX") || exit 1
trap 'rm -rf "$stage"' EXIT
ditto build/Readme.app "$stage/Readme.app" || exit $?
ln -s /Applications "$stage/Applications" || exit $?

rm -f build/Readme.dmg
hdiutil create -volname Readme -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -ov -quiet build/Readme.dmg || exit $?
echo "Packaged build/Readme.dmg ($(du -h build/Readme.dmg | cut -f1 | tr -d ' '))"
