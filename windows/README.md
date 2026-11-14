# Readme for Windows

The Windows app: WinUI 3 and WebView2 on .NET 10, sharing the Mac app's web layer (`Readme/Web/`),
fixtures and file formats. What's built so far, and what's next, is in
[`docs/Readme for Windows checklist.md`](../docs/Readme%20for%20Windows%20checklist.md).

Needs Windows 11, Visual Studio 2026 with the WinUI / Windows App SDK workload (or just the .NET 10
SDK, pinned by `global.json`), and the WebView2 runtime, which comes with Edge.

## Build and run

```
cd windows/Readme.App
dotnet build -p:Platform=x64 -r win-x64
```

This build is unpackaged, so it runs straight from `bin\x64\Debug\…\win-x64\Readme.exe`. Use
`-p:Platform=ARM64 -r win-arm64` on an ARM PC. Core tests: `dotnet test windows/Readme.slnx`.

Where it keeps things: the library in `Documents\Readme` (which may be in OneDrive), and settings,
window placement and WebView2's data in `%LOCALAPPDATA%\Readme`.

## Self-checks

`Readme.exe --checks <out> <mode> …` drives the real app and writes `<mode>.json` and screenshots to
`<out>`, then closes. Set `README_DATA_DIR` to a scratch folder first, so your own library is never
touched. Modes: `read <book.epub>`, `resume`, `shelf <fixtures>`, `tools <fixtures>`,
`bundles <fixtures>`, `instance <fixtures>`, `whole <book.epub>`, `calibrate <long.epub> <wide.epub>`,
where `<fixtures>` is `ReadmeTests/Fixtures`.

## One app at a time

A second launch never opens a second window. Double-clicking a book or a `.readmelibrary` while
Readme is open, or opening it again from the Start menu, hands the files to the running app, which
comes to the front, and the second launch quits. Instances are told apart by their library folder,
so a self-check with its own `README_DATA_DIR` runs beside your own Readme.

## The MSIX package

```
dotnet build -c Release -p:Platform=x64 -r win-x64 -p:ReadmePackage=true
```

writes an unsigned `Readme.App_<version>_x64.msix` to `bin\Packages\`. It registers Readme for
`.epub` and `.readmelibrary`. The Windows workflow (`.github/workflows/windows.yml`, run from the
Actions tab or with the `run-tests` label) builds it for x64 and ARM64 and keeps both as artifacts.

**Signing:** none here. The package is for the Microsoft Store, which signs what it's given, so
there's no certificate in the repo or in CI. An unsigned MSIX won't install by double-click.

**Trying the package before the Store:** with Developer Mode on, register the build's layout, which
needs no signature:

```
Add-AppxPackage -Register bin\x64\Release\net10.0-windows10.0.26100.0\win-x64\AppxManifest.xml
```

and remove it again with `Get-AppxPackage Readme.Reader | Remove-AppxPackage`. A packaged Readme
uses the same `Documents\Readme` library as the unpackaged one.

**Releasing:** `scripts/windows-release.ps1` sets the version from `project.yml` and builds both
packages into `windows/dist`; see `docs/releasing.md`, "Windows", and the listing draft in
`docs/windows-store-listing.md`.

## The GitHub installer

`scripts/windows-installer.ps1` publishes the app self-contained (it carries .NET and the parts of
the Windows App SDK it uses, so the PC needs nothing first) and wraps it with Inno Setup 6, from
`windows/installer/Readme.iss`, into `windows/dist/Readme-Setup-<version>-x64.exe` and `-arm64.exe`.
The installer:

- installs for the current user into `%LOCALAPPDATA%\Programs\Readme`, with no administrator
  rights, or for everyone into Program Files if chosen;
- adds a Start menu entry, Readme to **Open with** for `.epub` (it never takes EPUBs over from
  another app) and to **Default apps**, and opens `.readmelibrary` files;
- closes a running Readme before updating it, and replaces the whole app folder;
- on uninstall removes the app, its file types and `%LOCALAPPDATA%\Readme` (settings and
  WebView2's cache), and keeps the library in `Documents\Readme`.

The release workflow builds and attaches both on each tag.

**Before the first Store upload:** reserve the name in Partner Center and copy its package identity
(`Identity Name` and `Publisher`) and publisher display name into `Readme.App/Package.appxmanifest`;
the ones there are placeholders. `Version` is the release script's to set, from the Mac's
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, with a fourth part of 0.

## Privacy, on Windows

The README's Windows section says it: a Store desktop app runs with full trust rather than in a
sandbox, so the Mac's "sandboxed" line doesn't apply. What does: no accounts, no tracking, only the
books the reader gives it, the library in `Documents\Readme`, and no network from the app itself.
