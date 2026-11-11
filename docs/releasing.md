# Releasing an update

Readme has no automatic updates yet, so each release is a new download that people install over the old one.
Their books, reading places and settings are kept, because they live outside the app.

## Steps

1. Make the change and try it in the app.
2. Raise the version in `project.yml`, under the Readme target:
   - `MARKETING_VERSION` is what people see, for example `1.1`.
   - `CURRENT_PROJECT_VERSION` is the build number. Raise it by one every release, even for a small fix.
3. Run the tests: `scripts/test.sh`.
4. Build the download: `scripts/package.sh`. It makes a clean `build/Readme.dmg`.
5. Check it: `scripts/check_release.sh`. Quit Readme and eject any Readme disk first, or the check stops.
6. Commit, then mark the release with a tag and push both:
   `git tag v1.1` and `git push origin v1.1`, after the usual `git push`.
   The tag must match `MARKETING_VERSION`.
7. The tag starts the Release workflow on GitHub. It builds the DMG, publishes it as the GitHub release
   for the tag and updates the Homebrew cask. Watch it under the repo's **Actions** tab; details,
   and the steps to do it by hand, are in `docs/homebrew.md`.
   Testers without Homebrew can still be sent the DMG from the release page.

## What testers do

Quit Readme, open the new DMG and drag Readme into Applications, choosing **Replace**.
Readme isn't signed with an Apple developer account yet, so macOS may show the "can't verify" message again.
The steps are in `docs/install.md` (System Settings > Privacy & Security > **Open Anyway**).

## Later

An Apple developer account (paid yearly) removes that message by signing and notarising the app.
It is also needed before the app can update itself, which would use Sparkle: the app checks a web address
for a newer DMG and offers to install it.
