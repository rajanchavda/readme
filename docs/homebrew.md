# Installing with Homebrew

Readme is available through its own Homebrew tap (free, no Apple developer account needed).

```
brew install --cask rajanchavda/tap/readme
```

Update with `brew upgrade --cask readme`. Remove with `brew uninstall --cask readme`.

The cask clears macOS's download flag after installing, so there's no "can't verify" message to click through.

## One-time setup (for the maintainer)

1. On GitHub create a public repo named **`homebrew-tap`** under `rajanchavda`.
2. Clone it and add a `Casks/` folder. Homebrew reads `rajanchavda/tap` as `rajanchavda/homebrew-tap`.

## Every release

1. Run `scripts/release.sh`. It writes `build/Readme-<version>.dmg`, its checksum and `build/readme.rb`.
2. On GitHub, create a release for the tag (`v<version>`) in the `readme` repo and upload the DMG and the `.sha256` file.
3. Copy `build/readme.rb` to `Casks/readme.rb` in `homebrew-tap`, commit and push.
4. Check it: `brew update && brew reinstall --cask rajanchavda/tap/readme`, then `brew audit --cask --strict rajanchavda/tap/readme`.

The release must exist and the DMG be uploaded before step 3, or the cask's download fails.

## Checking a download by hand

```
shasum -a 256 -c Readme-<version>.dmg.sha256
```
