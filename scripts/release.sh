#!/bin/bash
# Usage: scripts/release.sh
# Packages the app, then prepares what a GitHub release and a Homebrew cask need:
#   build/Readme-<version>.dmg      the download, named for its version
#   build/Readme-<version>.dmg.sha256
#   build/readme.rb                 the cask, to copy into the tap as Casks/readme.rb
set -o pipefail
cd "$(dirname "$0")/.." || exit 1

repo=rajanchavda/readme
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -1)
[ -n "$version" ] || { echo "Couldn't read MARKETING_VERSION from project.yml" >&2; exit 1; }

scripts/package.sh || exit $?

dmg="build/Readme-$version.dmg"
cp build/Readme.dmg "$dmg" || exit $?
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
echo "$sha  Readme-$version.dmg" > "$dmg.sha256"

cat > build/readme.rb <<CASK
cask "readme" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/Readme-#{version}.dmg"
  name "Readme"
  desc "EPUB reader for the Mac"
  homepage "https://github.com/$repo"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Readme.app"

  # The app isn't signed with an Apple developer account, so Gatekeeper would block it.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Readme.app"]
  end

  zap trash: [
    "~/Library/Containers/com.rajanchavda.Readme",
  ]
end
CASK

echo
echo "Version  $version"
echo "File     $dmg"
echo "SHA-256  $sha"
echo "Cask     build/readme.rb"
echo
echo "Next: see docs/releasing.md (upload the DMG to the v$version release, then update the tap)."
