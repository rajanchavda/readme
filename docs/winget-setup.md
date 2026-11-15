# Putting Readme on winget

A one-time setup. When it's done, Windows users can run `winget install rajanchavda.Readme`, and
every later release reaches winget by itself through the Release workflow's `winget` job.

Tick each step as you go.

## 1. Merge the workflow change

- [ ] Open https://github.com/rajanchavda/readme/pull/new/ci/winget-release, create the pull
      request and merge it.

v1.6 was tagged before this change, so v1.6 goes to winget by hand (step 4). Releases from v1.7
on are automatic.

## 2. Make a GitHub token for winget

The workflow uses it to open the winget pull request from your account.

- [ ] Signed in to GitHub as **rajanchavda**, open **Settings > Developer settings > Personal
      access tokens > Tokens (classic) > Generate new token (classic)**.
- [ ] Note: `readme winget`. Expiration: your choice; a year is sensible, with a reminder to
      renew it.
- [ ] Tick only the **`public_repo`** scope, then **Generate token**, and copy it. GitHub shows it
      only once.

## 3. Add the token to the repo

- [ ] Open https://github.com/rajanchavda/readme/settings/secrets/actions and click **New
      repository secret**.
- [ ] Name: `WINGET_TOKEN`. Secret: the token from step 2. Click **Add secret**.

## 4. Submit v1.6 by hand (on a Windows PC)

The v1.6 installers are already on the release:

- x64: https://github.com/rajanchavda/readme/releases/download/v1.6/Readme-Setup-1.6-x64.exe
- arm64: https://github.com/rajanchavda/readme/releases/download/v1.6/Readme-Setup-1.6-arm64.exe

In PowerShell:

- [ ] Install the tool: `winget install Microsoft.WingetCreate`, then open a new PowerShell
      window.
- [ ] Give it your token, so it submits from your account:
      `wingetcreate token --store --token <the token from step 2>`
- [ ] Start the submission:

      wingetcreate new https://github.com/rajanchavda/readme/releases/download/v1.6/Readme-Setup-1.6-x64.exe https://github.com/rajanchavda/readme/releases/download/v1.6/Readme-Setup-1.6-arm64.exe

- [ ] Answer its questions:

  | Question | Answer |
  | --- | --- |
  | PackageIdentifier | `rajanchavda.Readme` (exactly this; the workflow looks for it) |
  | PackageVersion | `1.6` |
  | Publisher | `Rajan Chavda` |
  | PackageName | `Readme` |
  | License | `Proprietary` (the repo has no LICENSE file; use the real one if you add it) |
  | ShortDescription | `A quiet EPUB reader with a two-page spread, page curl, highlights and search.` |
  | Installer type, if asked | `inno` |
  | Architecture, if asked | `x64` for the first URL, `arm64` for the second |
  | Scope, if asked | `user` |

  Optional fields worth filling when it offers them: PublisherUrl
  `https://github.com/rajanchavda`, PackageUrl `https://github.com/rajanchavda/readme`, Tags
  `epub`, `ebook`, `reader`.
- [ ] Optional: test it before submitting. In an administrator PowerShell, run
      `winget settings --enable LocalManifestFiles`, then
      `winget install --manifest <the folder wingetcreate saved the manifest in>`. Check that Readme
      opens from the Start menu, then uninstall it.
- [ ] When it asks whether to submit, say **yes**. It forks `microsoft/winget-pkgs` under your
      account and opens a pull request. Keep the link it prints.

## 5. Get the winget pull request merged

- [ ] Watch the pull request on github.com/microsoft/winget-pkgs. Bots validate the manifest and
      scan the installers, and a moderator merges it, usually within a few days. An unsigned
      installer is allowed but can take longer.
- [ ] If a bot labels it `Needs-Author-Feedback` or comments on a problem, fix it with
      `wingetcreate update rajanchavda.Readme --version 1.6 --urls "<x64 url>|x64" "<arm64 url>|arm64" --submit`
      or by editing the files in your fork's branch.

## 6. After it's merged

- [ ] On any Windows PC: `winget search rajanchavda.Readme` finds it, and
      `winget install rajanchavda.Readme` installs it. Allow up to a day after the merge for winget's
      index to catch up.
- [ ] Tell users about it: add a "With winget" section to `docs/install-windows.md` and a line to
      the README's Windows section (`winget install rajanchavda.Readme`, and
      `winget upgrade rajanchavda.Readme` to update). Claude can do this.
- [ ] Tick winget off in `docs/Readme for Windows checklist.md`.

## From now on

Nothing to do per release. Tagging `v1.7` builds the DMG, then the Windows installers, then the
`winget` job opens the winget pull request. Check that job in the run's summary on the **Actions**
tab:

- **Green, no warning:** the winget pull request is open; Microsoft merges it in a few days.
- **Warning "WINGET_TOKEN is not set":** step 3 is missing, or the token was deleted.
- **Warning "isn't in winget-pkgs yet":** step 5 hasn't been merged yet.
- **Red:** usually an expired token. Make a new one (step 2), replace the secret (step 3), and
  submit that version by hand with the `wingetcreate update` command above.

The release itself, Mac and Windows, is never held up by winget.
