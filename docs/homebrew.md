# Installing with Homebrew

Readme is available through its own Homebrew tap (free, no Apple developer account needed).

```
brew install --cask rajanchavda/tap/readme
```

Update with `brew upgrade --cask readme`. Remove with `brew uninstall --cask readme`.

The cask clears macOS's download flag after installing, so there's no "can't verify" message to click through.

## One-time setup (for the maintainer)

The tap is the public repo `rajanchavda/homebrew-tap`, which also holds the casks of other apps.
Homebrew reads `rajanchavda/tap` as `rajanchavda/homebrew-tap`.

The `readme` repo needs the Actions secret **`HOMEBREW_TAP_TOKEN`**: a token allowed to push to
`homebrew-tap` (the same one the other apps' release workflows use). Add it under
Settings > Secrets and variables > Actions.

## Every release

Pushing a tag `v<version>` runs `.github/workflows/release.yml`, which:

1. checks the tag matches `MARKETING_VERSION` in `project.yml`,
2. runs the tests, then `scripts/release.sh` and `scripts/check_release.sh`,
3. creates the GitHub release with `Readme-<version>.dmg` and its `.sha256`,
4. copies the generated `build/readme.rb` to `Casks/readme.rb` in `homebrew-tap` and pushes it.

Then check it: `brew update && brew reinstall --cask rajanchavda/tap/readme`, and
`brew audit --cask --strict rajanchavda/tap/readme`.

### By hand, if the workflow can't run

1. Run `scripts/release.sh`. It writes `build/Readme-<version>.dmg`, its checksum and `build/readme.rb`.
2. On GitHub, create a release for the tag (`v<version>`) in the `readme` repo and upload the DMG and the `.sha256` file.
3. Copy `build/readme.rb` to `Casks/readme.rb` in `homebrew-tap`, commit and push.

The release must exist and the DMG be uploaded before step 3, or the cask's download fails.

## Checking a download by hand

```
shasum -a 256 -c Readme-<version>.dmg.sha256
```
