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

## How the app updates itself

It doesn't need the developer account. **Check for Updates…** asks GitHub's API for the latest release
(drafts and prereleases are skipped). **Update and Restart** starts Readme Updater
(`Readme.app/Contents/Helpers/Readme Updater.app`, built from `Updater/` and `Shared/`) and quits.
The updater isn't sandboxed and takes no instructions from Readme. It looks up the release itself,
then either runs `brew upgrade --cask readme` (when Homebrew installed the copy in Applications) or
downloads `Readme-<version>.dmg`, checks it against the `.sha256` beside it, checks the app inside
is signed and has the expected identifier and version, and swaps it in. Any failure leaves the old
app in place. So every release needs the DMG and its `.sha256` attached, as `release.yml` does,
and the tag and `MARKETING_VERSION` must agree.

## Windows

The Windows app ships through the Microsoft Store, which signs it and updates it; there's no
download or updater to look after. Its version follows the Mac's: `MARKETING_VERSION` 1.5 and
`CURRENT_PROJECT_VERSION` 7 make package version 1.5.7.0.

1. Raise the version in `project.yml` as above. Every Store submission needs a higher version than
   the last, so raise `CURRENT_PROJECT_VERSION` even for a Windows-only fix.
2. On Windows, run `powershell -ExecutionPolicy Bypass -File scripts\windows-release.ps1 -Store`.
   It writes the version into `windows/Readme.App/Package.appxmanifest`, runs the Core tests and
   builds `windows/dist/Readme-<version>-x64.msix` and `-arm64.msix`, each with a `.sha256`.
   It stops if the package identity is still the placeholder: the first time, copy it from
   Partner Center as `docs/windows-store-listing.md` describes.
3. Try the x64 package before uploading: with Developer Mode on, register the build's layout
   (`windows/README.md`, "Trying the package before the Store"), open a book, turn a few pages,
   then remove it.
4. Commit the manifest's new version, and tag as for the Mac.
5. In Partner Center, start a new submission, upload both packages on **Packages**, write
   **What's new** on the listing, and submit. Certification usually takes a few days; the Store then
   offers the update to everyone who has Readme.

The Windows workflow (`.github/workflows/windows.yml`, run from the Actions tab) builds the same
two packages as artifacts, for a check that they build on a clean machine.

### The GitHub installers

The tag that releases the Mac app also releases Windows on GitHub: once the Release workflow has
published the DMG, its `windows` job runs `scripts/windows-installer.ps1` and adds
`Readme-Setup-<version>-x64.exe` and `-arm64.exe`, each with a `.sha256`, to the same release.
Nothing else to do. They aren't signed, so SmartScreen asks once before running them
(`docs/install-windows.md`); a code-signing certificate would end that.

To build them yourself, install Inno Setup 6 (`winget install JRSoftware.InnoSetup`) and run
`powershell -ExecutionPolicy Bypass -File scripts\windows-installer.ps1`. Try one before tagging:
run it, open a book from the Start menu entry, double-click an EPUB, then uninstall from
Settings > Apps.
