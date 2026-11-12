# Readme for Windows: progress checklist

Tracks the work in [Readme for Windows phased build plan](Readme%20for%20Windows%20phased%20build%20plan.md). The plan says *what* and *why*; this file says *where we are*.

## How to resume

1. Read **Current state** below, then `git status` and `git log -5` to confirm it.
2. Pick up the first unticked item in the current phase.
3. Tick items as soon as they're done and committed, and update **Current state** before stopping. A ticked item means committed, not just written.

On a new machine, start the first Claude session with "read `docs/Readme for Windows checklist.md`": Claude's memory notes are per machine and don't travel with the repo. Also recreate the personal instructions file that sits above the repo (`~/Documents/personal/CLAUDE.md`), which isn't in git: never use the `gh` CLI, use plain `git`; and keep temporary files in a git-ignored `scratchpad/` folder at the project root.

## Current state

- **Phase:** not started
- **Branch:** none yet
- **Last thing done:** plan written and reviewed (Nov 11, 2026)
- **Next step:** settle the blocking decisions, then set up a Windows machine (prerequisites below)
- **Notes / blockers:** no .NET SDK on the Mac yet. `Readme.Core` can build and test on macOS, but everything WinUI 3 and WebView2 needs Windows.

## Prerequisites

- [ ] Windows machine or VM (x64 or arm64) with Visual Studio 2022, the Windows App SDK workload and the WebView2 runtime
- [ ] .NET SDK on the Mac too (`brew install --cask dotnet-sdk`), for working on `Readme.Core` here
- [ ] Repo cloned on the Windows machine, and git line endings agreed (`.gitattributes`), so shared files in `Readme/Web/` and the fixtures don't get rewritten with CRLF

## Decisions

Blocking: settle before the phase shown.

- [ ] Packaging: MSIX or unpackaged with a classic installer (before phase 0, since it shapes the project template)
- [ ] Minimum Windows version: 10 or 11 only (before phase 0)
- [ ] Uninstall deletes the library under MSIX: accept and document, or store it in Documents (before phase 1)
- [ ] Mouse wheel: one notch turns a page, or does nothing as on Mac (before phase 2)
- [ ] Freeze Mac features until Windows reaches parity? (before phase 1)
- [ ] Distribution: Microsoft Store, paid-signed download, or both (before phase 6)
- [ ] Ship v1 after phase 6 with a slide, or wait for the curl (before phase 6)

## Phase 0: Spike

Throwaway. Goal is to prove the risky assumptions.

- [ ] Empty WinUI 3 app in `windows/` hosting a WebView2
- [ ] `readme-book://app/` registered as a custom scheme (authority, secure, own origin allowed), serving `reader.html` with the same CSP. If it fails, fall back to a virtual `https://` host and note it here
- [ ] `bridge.js`: one `post()` helper (WebKit handler or `chrome.webview.postMessage`) replacing the 4 call sites; Mac build and tests still pass
- [ ] `long.epub` opens as a two-page spread
- [ ] `ready` and `relocate` messages arrive in C#
- [ ] `bridge.js`: Windows-only `keydown` and `wheel` forwarding in the per-document load hook; an arrow key pressed after clicking the page reaches C#
- [ ] Wheel deltas reach C#
- [ ] Remote loads blocked in `WebResourceRequested` (http, https, ws), navigations and new windows cancelled; the remote-image fixture makes no network request
- [ ] Browser features off: accelerator keys, context menu, dev tools, zoom, pinch zoom, swipe navigation
- [ ] In-private mode, user data folder in app data
- [ ] Async script calls: request id in, result posted back (or DevTools evaluate). Pick one and note it here
- [ ] A second, never-shown WebView2 opens a book and returns a snapshot via `CapturePreviewAsync`
- [ ] All 24 fixtures open (or fail the same way they do on Mac); note any Chromium pagination differences here
- [ ] Spike findings written up in this file; plan amended if anything changed

## Phase 1: Core library

- [ ] `windows/` solution with `Readme.Core` and `Readme.Core.Tests` (MSTest), fixtures linked from `ReadmeTests/Fixtures/`
- [ ] Golden files committed to shared fixtures: a `library.json`, a highlights file, one exported `.readmelibrary`; a Swift test reads them too
- [ ] `Book.cs`, same SHA-256 id scheme (golden check: same id as on Mac)
- [ ] `ReaderLocation.cs`
- [ ] Zip reader port (same read limits, ZIP64 refused)
- [ ] `ZipWriter.cs` port (stored or deflated only, no ZIP64)
- [ ] `EpubInspector.cs`
- [ ] `LibraryStore.cs` (`library.json`, `Books/`, `Covers/`)
- [ ] `PositionStore.cs`
- [ ] `HighlightStore.cs`
- [ ] `MarkerStore.cs`
- [ ] Layout maths
- [ ] Core tests pass, including the 8 DRM fixtures and the junk-file ones

## Phase 2: Reader basics

- [ ] `BookScheme.cs` and `BookWebView.cs` rebuilt properly from the spike
- [ ] `App.xaml.cs`, `AppCoordinator.cs`, `LaunchRoute.cs`, `BundledFonts`
- [ ] `ReaderPage` with root grid (desk), spine shadow
- [ ] `ReaderCommand.cs` with Windows key mapping; keys from the page plus `KeyboardAccelerator` backup
- [ ] `ReaderSettings.cs` saved to `settings.json`
- [ ] `ReadingCss.cs`; WebKit workarounds re-checked under Chromium (hyphenation, long words, wide tables)
- [ ] `SpreadLayout.cs`, `BookFrame.cs`, `PlaceKeeper.cs`
- [ ] Page turns with slide or fade
- [ ] Themes, fonts (Fraunces in place of New York), text size, line width
- [ ] Resume position; stores flushed on close
- [ ] Full screen (F11)
- [ ] One-page layout for narrow windows
- [ ] Reduce-motion setting
- [ ] Window size and position remembered
- [ ] **Done when:** read a whole book, quit, reopen on the same page

## Phase 3: Library shelf

- [ ] `LibraryPage.xaml`, `CurrentBookShelf`, `ShelfRow`, `BookCover` controls
- [ ] `ShelfLayout.cs`, `ShelfSelection.cs` (Ctrl and Shift)
- [ ] File picker import
- [ ] Drag-and-drop import (`DragOver`, `Drop`)
- [ ] `BookImporter.cs` with hidden WebView2 check; cover extraction via `BitmapDecoder`
- [ ] `GeneratedCover.cs` with Win2D (12 palettes, FNV-1a pick)
- [ ] `LastSpreadCache.cs` placeholder
- [ ] Remove book; right-click menu (Export arrives in phase 5)
- [ ] Import failure notices
- [ ] **Done when:** import 5 books, see covers, open and switch between them

## Phase 4: Reading tools

- [ ] `ReaderToolbar` with auto-hide (`IdleTimer.cs`); cursor hiding
- [ ] `TocSidebar`, `TocProgress.cs`
- [ ] `GoToPageField`
- [ ] `Search.cs`, `SearchBox`
- [ ] `HighlightBar`, `HighlightsSidebar`
- [ ] `MarkerRibbon`
- [ ] `ShortcutsHelp.cs` (Windows key names), `ShortcutsPanel`; every shortcut listed in it
- [ ] Tooltips, Narrator labels, error sound
- [ ] **Done when:** every row of the shortcut mapping table works

## Phase 5: Export and import

- [ ] `.readmelibrary` format spec written in `docs/`
- [ ] `LibraryBundle.cs`, `LibraryExporter.cs`, `LibraryImporter.cs`
- [ ] Never replace; keep mine or combine; newer format refused whole; size limits match
- [ ] Shelf Export, including multi-selection
- [ ] **Done when:** Mac export imports on Windows with highlights, marker and position intact, and the reverse

## Phase 6: Windows integration

- [ ] `.epub` and `.readmelibrary` file associations
- [ ] Single instance with file-open redirection
- [ ] Auto theme follows Windows
- [ ] Packaging per the decision above
- [ ] README's "sandboxed" claim handled for Windows
- [ ] CI on `windows-latest` (Core tests, then app tests with WebView2 runtime)
- [ ] Signing per the decision above
- [ ] **Done when:** double-clicking an EPUB opens it in the running app; installer builds in CI

## Phase 7: Page curl

- [ ] `CurlPose.cs`, `SwipeTracker.cs` (end swipe on a pause in deltas), `TurnCoordinator.cs`
- [ ] `SpreadCache.cs` with a second WebView2
- [ ] `CurlView.cs` with Composition strips
- [ ] Frame timing check via `CompositionTarget.Rendering`
- [ ] Rapid-turn handling
- [ ] If snapshots are too slow: CSS curl fallback, noted here
- [ ] **Done when:** curl matches `docs/mockups/open-book-v2.html` and survives held-key rapid turns

## Phase 8: Release

- [ ] Store listing or signed installer
- [ ] Windows install docs (including the uninstall note if MSIX)
- [ ] Release script
- [ ] README section for Windows
- [ ] **Done when:** someone else installs it from the install docs alone
