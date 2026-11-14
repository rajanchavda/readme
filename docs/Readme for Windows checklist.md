# Readme for Windows: progress checklist

Tracks the work in [Readme for Windows phased build plan](Readme%20for%20Windows%20phased%20build%20plan.md). The plan says *what* and *why*; this file says *where we are*.

## How to resume

1. Read **Current state** below, then `git status` and `git log -5` to confirm it.
2. Pick up the first unticked item in the current phase.
3. Tick items as soon as they're done and committed, and update **Current state** before stopping. A ticked item means committed, not just written.

On a new machine, start the first Claude session with "read `docs/Readme for Windows checklist.md`": Claude's memory notes are per machine and don't travel with the repo. Also recreate the personal instructions file that sits above the repo (`~/Documents/personal/CLAUDE.md`), which isn't in git: never use the `gh` CLI, use plain `git`; and keep temporary files in a git-ignored `scratchpad/` folder at the project root.

## Current state

- **Phase:** 8, waiting on the owner. Everything that can be built is built; what's left needs Partner Center, GitHub, the Mac or a person's hands
- **Branch:** `feat/windows-phase-0-1`, on `main` at v1.5, pushed (phase 2 is on it too)
- **Last thing done:** phase 8 (Nov 14, 2026): the release script, install docs, README section and Store listing draft. Before that, phases 0 to 7: see their findings
- **Next step:** for the owner. (0) Version 1.6 (build 8) is set for the first release with Windows: after merging, run the Mac tests (`scripts/test.sh`, which now cover two `bridge.js` changes), then tag `v1.6`; the Release workflow adds the Windows installers to it. (1) Run the Windows workflow once from the Actions tab. (2) Reserve the name in Partner Center, copy the identity into `Package.appxmanifest`, put up the privacy page, run `scripts/windows-release.ps1 -Store` and submit, following `docs/windows-store-listing.md`. (3) Have someone install it from `docs/install-windows.md` alone. Still to try by hand: the curl's feel with a real touchpad and keyboard (phase 7), dragging books and bundles from File Explorer onto the shelf (phases 3 and 5), reduce motion (phase 2), and Narrator over the reading tools (phase 4). On the Mac: run the Swift tests (they now cover two `bridge.js` changes and read the Windows-made bundle), export a bundle into `Fixtures/Golden/` for the Windows tests, and carry bundles both ways between the two apps, which is phase 5's "done when"
- **Notes / blockers:** no .NET SDK on the Mac yet. `Readme.Core` can build and test on macOS, but everything WinUI 3 and WebView2 needs Windows. VS 2026 also installs the .NET 11 SDK, so `windows/global.json` pins 10.0.x. Developer Mode and long paths are on on the Windows machine

## Prerequisites

- [x] Windows machine or VM (x64 or arm64) with Visual Studio 2026, the WinUI / Windows App SDK workload, the .NET 10 SDK (LTS) and the WebView2 runtime. Changed from VS 2022 on Nov 12, 2026: VS 2022 stops at .NET 9, and .NET 8 and 9 both leave support in Nov 2026
- [ ] .NET SDK on the Mac too (`brew install --cask dotnet-sdk`), for working on `Readme.Core` here
- [x] Repo cloned on the Windows machine, and git line endings agreed (`.gitattributes`), so shared files in `Readme/Web/` and the fixtures don't get rewritten with CRLF

## Decisions

Blocking: settle before the phase shown.

- [x] Packaging: MSIX or unpackaged with a classic installer (before phase 0, since it shapes the project template). **Decided Nov 13, 2026: MSIX (single-project packaged), shipped through the Microsoft Store.** The Store signs it for free (an unsigned MSIX won't install at all) and handles updates, so the Mac's Readme Updater isn't ported. This also settles the distribution decision below
- [x] Minimum Windows version: 10 or 11 only (before phase 0). **Decided Nov 13, 2026: Windows 11 only**, `TargetPlatformMinVersion` 10.0.22000.0. Windows 10 consumer extended updates ended Oct 2026, the Mac app likewise targets a recent OS only (macOS 14), and there's no Windows 10 machine to test on
- [x] Uninstall deletes the library under MSIX: accept and document, or store it in Documents (before phase 1). **Decided Nov 13, 2026: `Documents\Readme`.** It survives uninstall and reinstall as on Mac (an MSIX app has no uninstall hook to warn from), the user can see and back it up, and Calibre does the same. A full-trust MSIX app writes there unvirtualized. Settings and WebView2 data stay in app data. Write the JSON stores atomically (temp file, then replace), since OneDrive or a backup tool may read Documents mid-write. Install docs mention that Documents may sync to OneDrive
- [x] Mouse wheel: one notch turns a page, or does nothing as on Mac (before phase 2). **Decided Nov 13, 2026: a mouse wheel does nothing, as on Mac.** Only a touchpad swipe turns the page. Windows doesn't label wheel events by device, so phase 2 has to tell the two apart (a notch arrives as a whole multiple of 120 with no horizontal part; touchpad deltas are small and often horizontal), and the spike's one-notch-a-page handling goes
- [x] Freeze Mac features until Windows reaches parity? (before phase 1). **Decided Nov 13, 2026: soft freeze until phase 6.** No new Mac features; bug fixes allowed, and a fix that touches the shared contract (`Readme/Web/`, store JSON, `.readmelibrary`) lands on Windows in the same PR. New ideas go in `docs/future-todos.md`. Shelf search and pinning (both released Nov 13, v1.4 and v1.5) came before the freeze and are ported: see **Mac features added since the plan**
- [x] Distribution: Microsoft Store, paid-signed download, or both (before phase 6). **Microsoft Store**, which follows from the packaging decision above
- [x] Ship v1 after phase 6 with a slide, or wait for the curl (before phase 6). **Decided Nov 14, 2026: wait for the curl**, and build phases 7 and 8

## Mac features added since the plan

Released on Nov 13, 2026, before the freeze, so the port includes them. Their Swift code and specs are the spec: `docs/pin-to-front.md` and `docs/superpowers/specs/2026-11-13-shelf-search-design.md`. The items are repeated in the phases below.

- **Pin to front (v1.4).** Changes the shared contract: `pinnedAt` (ISO 8601, optional) on `Book` in `library.json` and on `BundledBook` in `.readmelibrary`. Without it, a library going Mac → Windows → Mac loses its pins.
- **Shelf search (v1.5).** Windows only needs the UI. Ctrl+F on the shelf in place of ⌘F, and no new formats.
- **Quitting for an update (v1.4.1).** Mac Updater only; nothing to port, since the Store does updates.

## Phase 0: Spike

Throwaway. Goal is to prove the risky assumptions.

- [x] Empty WinUI 3 app in `windows/` hosting a WebView2
- [x] `readme-book://app/` registered as a custom scheme (authority, secure, own origin allowed), serving `reader.html` with the same CSP. If it fails, fall back to a virtual `https://` host and note it here
- [ ] `bridge.js`: one `post()` helper (WebKit handler or `chrome.webview.postMessage`) replacing the 4 call sites; Mac build and tests still pass. **Windows half done; the Mac build and tests are still to run** (the Mac app will be tested once the Windows app is ready)
- [x] `long.epub` opens as a two-page spread
- [x] `ready` and `relocate` messages arrive in C#
- [x] `bridge.js`: Windows-only `keydown` and `wheel` forwarding in the per-document load hook; an arrow key pressed after clicking the page reaches C#
- [x] Wheel deltas reach C#
- [x] Remote loads blocked in `WebResourceRequested` (http, https, ws), navigations and new windows cancelled; the remote-image fixture makes no network request
- [x] Browser features off: accelerator keys, context menu, dev tools, zoom, pinch zoom, swipe navigation
- [x] In-private mode, user data folder in app data
- [x] Async script calls: request id in, result posted back (or DevTools evaluate). Pick one and note it here
- [x] A second, never-shown WebView2 opens a book and returns a snapshot via `CapturePreviewAsync`
- [x] All 24 fixtures open (or fail the same way they do on Mac); note any Chromium pagination differences here
- [x] Spike findings written up in this file; plan amended if anything changed

Every item above except the Mac half of the `bridge.js` item was verified on Windows on Nov 13, 2026 by `windows/Spike` (`ReadmeSpike.exe --checks <dir>`), and re-run after rebasing on v1.5.

### Spike findings

Machine: Windows 11 x64, Windows App SDK 2.6.5, WebView2 runtime 157, .NET 10.0.404. The spike is unpackaged so it runs from `dotnet build`; the app proper is MSIX.

- **Custom scheme works**, no `https://` fallback needed. `reader.html` loads from `readme-book://app` with the same CSP, as a secure context, and every fetch of the book and of foliate's modules goes through `WebResourceRequested`. Two traps in the WinRT projection of the WebView2 API: `CoreWebView2EnvironmentOptions.CustomSchemeRegistrations` returns a copy, so `.Add()` on it silently does nothing and the scheme is never registered (the navigation just aborts with `ConnectionAborted`); assign a new list instead. And `TreatAsSecure` is an `int`, not a `bool`. `AllowedOrigins` reads back empty the same way; it isn't needed while everything is same-origin.
- **Filters:** `AddWebResourceRequestedFilter` with `CoreWebView2WebResourceRequestSourceKinds.All`, so requests from book iframes are seen too. An exception thrown in the handler is swallowed and the request aborts, so the real handler must catch and answer 500.
- **Two-page spread:** `long.epub` opens with 2 columns of 546 px in a 1384 px view, 449 pages, page number drawn. `ready` and `relocate` arrive; `next()` posts one `relocate`.
- **Async calls: request id chosen.** `ExecuteScriptAsync` runs a wrapper that awaits the bridge call and posts `{type: 'reply', id, ok, value | error}` back; C# matches the id. No change to `bridge.js` needed for it, and it doesn't need DevTools.
- **Keys and wheel:** after a click on the page (focus lands on `FOLIATE-VIEW`), ArrowRight and Ctrl+F both reach C# as `key` messages, with accelerator keys off so Ctrl+F doesn't open find. Horizontal and vertical wheel deltas arrive as `wheel` messages (120 per notch, `deltaMode` 0). Tested with DevTools-protocol input, which works with `AreDevToolsEnabled` off; worth one manual check with a real keyboard and touchpad.
- **Remote loads:** the remote-image fixture's image is `blocked` (its `https://` URL is the only request caught by the filter). A `fetch` and a `WebSocket` from the reader page are stopped by the CSP before reaching the filter. `location.href = https://…` is cancelled in `NavigationStarting`, and both `window.open` calls are cancelled in `NewWindowRequested`. The link-hints fixture makes no remote request.
- **Book scripts never run:** the scripted fixture loads with its 2 scripts in place; `__pwned` stays false, the page title stays `Readme`, and no stray message arrives.
- **Browser features off** and in-private on, with the user data folder under `%LOCALAPPDATA%`.
- **Hidden view: plan change needed.** A bare `CoreWebView2Controller` parented to the WinUI window fails with `ERROR_INVALID_STATE` (0x8007139F) whatever the options. A XAML `WebView2` set to `Visibility.Collapsed`, or placed in a window that's never shown, hangs the UI thread in `EnsureCoreWebView2Async`. What works: a XAML `WebView2` at `Opacity = 0`, `IsHitTestVisible = false`, behind the reader in the same window. It opens `long.epub` in about 300 ms, paints (`document.hidden` false, 14% of pixels ink), and `CapturePreviewAsync` takes about 200 ms per spread, including after a page turn. So import (phase 3) and the curl cache (phase 7) use an invisible view in the visual tree, not an offscreen one. 200 ms a snapshot is slow for rapid turns; that's the phase 7 risk the plan already names.
- **Closing a hidden view can crash the app.** In about 1 run in 3, removing and closing the opacity-0 WebView2 straight after a snapshot ends the process with an access violation in `coreclr.dll` (0xC0000005); the other checks are unaffected. So the app proper creates its hidden view once and reuses it for every import and spread, never closing one mid-session. Worth a minimal repro and a WebView2 bug report if it shows up again in phase 3.
- **Fixtures:** 17 of 24 open through `bridge.js`: big-chapter 418 pages, broken-chapter 11, long 449, search 10, spreads 19, wide-content 14, and the rest 1 to 12. The 7 that fail do so in `bridge.js` or zip.js with sensible errors: `not-an-epub` (not an EPUB), `plain-zip` (no container), `pk-comment` (split zip), `drm-bad-size` and `drm-bomb` (invalid size), `drm-past-end` (junk after data), `drm-bad-xml` (XML error). The DRM fixtures that open (`drm`, `drm-lcp`, `drm-rights`, `drm-sinf`) are meant to be refused earlier by `EpubInspector` in phase 1, as on Mac. Not yet compared page by page with the Mac.
- **Still to check on the Mac:** the `bridge.js` change keeps the Mac build and tests passing. On Mac `postToApp` posts the same JSON strings as before, and the key and wheel forwarding is off unless `chrome.webview` is present and WebKit's handler isn't.

## Phase 1: Core library

- [x] `windows/` solution with `Readme.Core` and `Readme.Core.Tests` (MSTest), fixtures linked from `ReadmeTests/Fixtures/`
- [ ] Golden files committed to shared fixtures: a `library.json`, a highlights file, one exported `.readmelibrary`; a Swift test reads them too. **`library.json`, highlights, marker, position and ids are in; the `.readmelibrary` and a run of the Swift test wait for the Mac**
- [x] `Book.cs`, same SHA-256 id scheme (golden check: same id as on Mac), with `pinnedAt`; a `library.json` without it loads with nothing pinned
- [x] Golden `library.json` includes a pinned book
- [x] `ReaderLocation.cs`
- [x] Zip reader port (same read limits, ZIP64 refused)
- [x] `ZipWriter.cs` port (stored only, as the Mac writes; no ZIP64)
- [x] `EpubInspector.cs`
- [x] `LibraryStore.cs` (`library.json`, `Books/`, `Covers/`) rooted at `Documents\Readme`, with atomic writes; `SetPinned` and the shelf order (current book, then pins newest first, then by recency)
- [x] `ShelfSearch.cs`: title and author, case- and accent-insensitive, every word must match
- [x] `PositionStore.cs`
- [x] `HighlightStore.cs`
- [x] `MarkerStore.cs`
- [x] Layout maths
- [x] Core tests pass, including the 8 DRM fixtures and the junk-file ones

Everything above except the `.readmelibrary` golden file was built on Windows on Nov 13, 2026: `dotnet test windows/Readme.slnx` runs 92 tests, all passing. "Layout maths" here means `ShelfLayout` and `SpreadLayout`; `BookFrame` and `PlaceKeeper` need reader settings and CSS, so they stay in phase 2. The boxes stay unticked until committed. Still to do on the Mac: run `GoldenFilesTests.swift` (written, not yet run), and export a small `.readmelibrary` into `Fixtures/Golden/` for phase 5.

### Phase 1 findings

- **Dates differ by file, and the plan's "dates are ISO 8601" is only half right.** `library.json` and positions use `JSONEncoder`'s default: a number of seconds since 1 Jan 2001 UTC. Highlights, markers and bundles use `.iso8601`: whole seconds, `Z`, and the Mac's decoder **rejects fractional seconds**, so Windows never writes them. `Fixtures/Golden/README.md` has the table.
- **Date precision:** Swift's `Date` is a double, so it survives `library.json` exactly. A .NET date has 100 ns ticks, which a double can't hold that far from 2001. `Readme.Core` keeps library dates at whole microseconds (`ReferenceDateConverter.Normalize`), so a book read back equals the book saved; a 100,000-date sweep test guards it. Scaling seconds by a million directly broke for dates after about 2080; whole seconds and the fraction are now scaled separately.
- **Other contract details:** Swift writes UUIDs in upper case (C# would write lower), leaves out nil fields rather than writing `null`, and writes `/` as `\/`. The golden tests check that Windows reads the Mac's files and writes back the same JSON.
- **Golden files** live in `ReadmeTests/Fixtures/Golden/`. It's a folder reference in `project.yml`, so the Swift tests get them with no project change. `ids.json` pins the SHA-256 ids of three fixtures for both platforms.
- **Zip:** `ZipWriter` writes stored entries only (the Mac's does too, not "stored or deflated"). A .NET array stops just short of 2 GB, so `ZipReader.Data` refuses a book that large, where the Mac's 2 GB limit would allow one exactly 2 GB. Phase 5 should stream `book.epub` out of a bundle instead of reading it whole.
- **Inspector verdicts** match the Swift tests: the 8 `drm*` fixtures are copy-protected, `not-an-epub` and `plain-zip` aren't EPUBs, and the other 14 pass. XML is read with DTDs ignored and no entity expansion, as Swift's `XMLParser` does.
- **Stores are synchronous and thread-safe** (a lock each), where the Mac's are actors. Writing a place on every page turn without blocking the UI (`PlaceWriter`) belongs to phase 2. `LastSpreadCache` (phase 3) hooks in through `LibraryStore.Removing`.
- **Shelf search folding** drops combining marks and lower-cases. Letters with no decomposition (ø, ß, æ) aren't folded further; the Mac's `folding` may treat some of them differently.
- **Fraunces** has no measured character width yet. It borrows New York's 0.448 until phase 2 calibrates it in Chromium, along with re-checking the other two fonts.

## Phase 2: Reader basics

- [x] `BookScheme.cs` and `BookWebView.cs` rebuilt properly from the spike
- [x] `App.xaml.cs`, `AppCoordinator.cs`, `LaunchRoute.cs`, `BundledFonts`. `BundledFonts` came with phase 3: XAML loads the bundled fonts from `ms-appx:///Web/fonts/…`, which works unpackaged too
- [x] `ReaderPage` with root grid (desk), spine shadow (`ReaderView.cs`)
- [x] `ReaderCommand.cs` with Windows key mapping; keys from the page plus `KeyboardAccelerator` backup. The backup is a `KeyDown` handler on the window content, using the same mapping; it ignores keys while the page has the focus, since the page passes those on
- [x] `ReaderSettings.cs` saved to `settings.json`
- [x] `ReadingCss.cs`; WebKit workarounds re-checked under Chromium (hyphenation, long words, wide tables). Long words and wide content stay in their columns; Chromium doesn't hyphenate (see findings)
- [x] `SpreadLayout.cs`, `BookFrame.cs`, `PlaceKeeper.cs`
- [x] Page turns with slide or fade. foliate's own 300 ms slide, switched on from C#; the book fades in on open, and restyles crossfade from a snapshot
- [x] Themes, fonts (Fraunces in place of New York), text size, line width. Chosen from an "Aa" menu until the phase 4 toolbar
- [x] Resume position; stores flushed on close
- [x] Full screen (F11)
- [x] One-page layout for narrow windows
- [ ] Reduce-motion setting. **Built, not yet seen working:** follows Windows' "Animation effects" (`UISettings.AnimationsEnabled`), turning off the slide, fades and crossfade. Check by switching that setting off
- [x] Window size and position remembered
- [x] **Done when:** read a whole book, quit, reopen on the same page. `--checks <dir> whole` turns through all 449 pages of `long.epub` (479 turns), and `resume` reopens on the place saved

Built on Windows, Nov 13, 2026. `windows/Readme.App` is the app: run `bin\x64\Debug\…\win-x64\Readme.exe`, optionally with an `.epub` path to open. It isn't in `Readme.slnx` yet, since `dotnet test` on the solution would then need a Windows runtime identifier; build it with `dotnet build windows/Readme.App -p:Platform=x64 -r win-x64`. `Readme.Core` gained the phase 2 logic, and `dotnet test windows/Readme.slnx` now runs 129 tests.

### Phase 2 findings

- **Self-checks drive the real app.** `Readme.exe --checks <dir> read <book>` opens a book, sends real key presses into the page through the DevTools protocol, changes theme, font and size, narrows the window, goes in and out of full screen, and closes the way the close button does. `--checks <dir> resume` launches as usual and records where the book reopened, `whole <book>` reads a book from the first page to the last, and `calibrate <long> <wide>` measures line lengths. Each writes JSON and window screenshots. Set `README_DATA_DIR` to a scratch folder, so the reader's own library and settings are never touched.
- **An async trap in the restyle queue.** Before a book opens, a restyle has nothing to wait for, so it finished before it was stored, and the finished task stayed stored: every later restyle was skipped, and since the reader then always counted as "laying out", no place was ever saved. Fixed with a yield at the start; the self-check caught it.
- **The mouse wheel scrolled foliate's container**, which foliate took as a move. On Mac the app's scroll monitor swallows the wheel before WebKit sees it; here `bridge.js`'s Windows-only wheel listener cancels it, and the wheel does nothing, as decided.
- **Turns queued without end** when presses came faster than a turn takes (about 450 ms with foliate's slide), so the book trailed the reader and queued calls timed out. Now one turn may wait behind the one under way, and further presses are dropped, as are a held key's repeats. Phase 7's rapid-turn handling replaces this.
- **`Window.Close()` doesn't raise `AppWindow.Closing`**, so it would skip keeping the place and the window. Only a real close does (the close button, Alt+F4, or the `WM_CLOSE` the self-check sends).
- **Reopening can show the place on the facing page.** foliate pages by column: turning backwards from the end of a chapter with an odd number of columns aligns the spreads a column off from a fresh open, so a place that began the left page can reopen on the right page of the spread before. The place is on screen either way, and this is foliate's own behaviour, so the Mac does the same.
- **Line lengths hold in Chromium.** Measured as the Mac's LineLengthTests do (a 1600 by 900 view), Regular sets 51.3, 50.9 and 50.8 characters a line for EB Garamond, Literata and Fraunces, inside the Mac's 50 to 55, with Narrow and Wide more than 3 either side. So Fraunces keeps 0.448, now measured. In the app's normal 980 px book, lines run a few characters shorter than the targets on both platforms, since the bridge's column maths was calibrated at 1600.
- **Chromium doesn't hyphenate here.** `hyphens: auto` is applied, but WebView2 has no hyphenation dictionaries, so justified lines are a little looser than on Mac. Long words still break inside the column, and the wide-content fixture shows nothing running out of its column on any page.
- **Wider fonts drop to one page sooner.** At the default window, Fraunces and Literata show one page, as New York does on Mac, since two of their columns don't fit in 980 px.
- **Unpackaged for now.** The app runs straight from `dotnet build`; MSIX packaging is phase 6. The library is in `Documents\Readme`; settings, `window.json` and WebView2's data are in `%LOCALAPPDATA%\Readme`.
- **Until phase 3 there's no shelf.** The library is a plain list of books with an Open button (Ctrl+O); a book can also be opened by passing its path on the command line. Ctrl+L shows the list.

## Phase 3: Library shelf

- [x] `LibraryPage.xaml`, `CurrentBookShelf`, `ShelfRow`, `BookCover` controls. Built in code: `LibraryView.cs` (ledge, shelves, empty first-run ledge) and `BookCoverView.cs`
- [x] `ShelfLayout.cs`, `ShelfSelection.cs` (Ctrl and Shift)
- [x] File picker import. Ctrl+O; several files at once go to the shelf, one is opened
- [ ] Drag-and-drop import (`DragOver`, `Drop`). **Built, not yet tried by hand:** it uses the same import as Ctrl+O, which is tested, but a real drag from File Explorer can't be driven from the self-checks
- [x] `BookImporter.cs` with hidden WebView2 check; cover extraction via `BitmapDecoder`. The importer's flow is in `Readme.Core`, with the hidden view passed in; covers over 1200 px are scaled down
- [x] `GeneratedCover.cs` (12 palettes, FNV-1a pick). Drawn in XAML rather than Win2D: one TextBlock a line, measured in the same fonts, so no extra package
- [x] `LastSpreadCache.cs` placeholder
- [x] Remove book; right-click menu (Export arrives in phase 5)
- [x] Pin to Front and Unpin in the right-click menu, multi-selection titles as on Mac; ribbon on pinned covers in the marker colour; Narrator label ends ", pinned"
- [x] Shelf search: magnifier top-right, Ctrl+F opens it, Esc clears then falls through, filters in place, "No books match" line, Return opens a single match, cleared when a book opens
- [x] Import failure notices
- [x] **Done when:** import 5 books, see covers, open and switch between them. `--checks <dir> shelf <fixtures>` imports five books and refuses two, opens one and reads, goes back with Ctrl+L, switches to another, then picks, pins, searches and removes

Built on Windows, Nov 13, 2026. `Readme.Core` gained `BookImporter`, `ShelfSelection`, `GeneratedCover`, `ShelfText` and `LastSpreadCache`, with their Swift tests ported: `dotnet test windows/Readme.slnx` runs 162.

### Phase 3 findings

- **Import couldn't move the book it had just read.** WebView2 keeps a response's stream open for a while after reading it, and the book scheme opened files with `FileShare.Read`, so moving the staged copy into place failed and every import came back unreadable. The scheme now opens files with `FileShare.Delete` as well, which lets a file be moved or deleted while a stream is still open. Removing a book that's open relies on it too.
- **One hidden view, reused.** Import opens each book in a WebView2 at opacity 0 behind everything, made once and kept, one book at a time, since closing a WebView2 straight after use crashed the app in the spike. Five books import in about 1.5 s.
- **The last spread needs the real scale.** At launch the reader isn't in the window yet, so it read its scale as 1 and never matched a picture kept at 1.25. It now waits until it's laid out; the picture then shows within about 25 ms of launch, before the book opens.
- **Generated covers match the Mac's colours.** FNV-1a over the id picks the same palette on both platforms (the Mac test's id gets palette 7 on both). The layout maths is in Core with the measuring passed in, so it's tested with a stand-in font, and the app measures in the real bundled fonts.
- **Menus aren't in window screenshots.** WinUI 3 draws menus in their own popup window, which a window capture misses; the self-check reads the menu's items instead.
- **Done by the self-check rather than by hand:** Ctrl and Shift selection go through the covers' own click logic with the modifiers given, since sending modifier keys to another window isn't reliable from inside the app. The rings, menu titles and plain-click behaviour all match the Mac's.

## Phase 4: Reading tools

- [x] `ReaderToolbar` with auto-hide (`IdleTimer.cs`); cursor hiding. The pointer moving over the page wakes it through a Windows-only `pointermove` message from `bridge.js`; in full screen the pointer hides with the toolbar
- [x] `TocSidebar`, `TocProgress.cs`
- [x] `GoToPageField`
- [x] `Search.cs`, `SearchBox`
- [x] `HighlightBar`, `HighlightsSidebar`
- [x] `MarkerRibbon`
- [x] `ShortcutsHelp.cs` (Windows key names), `ShortcutsPanel`; every shortcut listed in it, including the Library section (Ctrl+F, Esc). A Core test checks that every key the panel names does what its row says
- [x] Tooltips, Narrator labels, error sound. Tooltips give the shortcut in brackets, Windows style. **Narrator itself not yet tried by hand:** the names are checked, not how it reads them
- [x] **Done when:** every row of the shortcut mapping table works. `--checks <dir> tools <fixtures>` presses each row's keys in the page and checks what it did, then works each tool: contents, go to page, the marker, highlights, search, the shortcuts panel, full screen, the toolbar's buttons and the shelf's Ctrl+F and Esc

Built on Windows, Nov 13, 2026. `Readme.Core` gained `ReadingTools.cs`: `IdleTimer`, `TocProgress`, `SearchResults`, `GoToPage`, `ChapterTimeLeft`, `ShortcutsHelp`, the tools' colours and the bar's and ribbon's placement, with their Swift tests ported: `dotnet test windows/Readme.slnx` runs 196.

### Phase 4 findings

- **WebView2 keeps the pointer to itself, like keys.** Moving the mouse over the page never reaches XAML, so the toolbar couldn't wake. `bridge.js` now posts a `pointer` message from the same Windows-only `forwardInput` that passes keys and the wheel on, a few times a second at most. A second change to `bridge.js` for the Mac build and tests to cover.
- **Hiding the pointer in full screen is done in the page.** WinUI 3 has no blank cursor to set over a WebView2, so the toolbar going to sleep puts `cursor: none` into the reader's document and each chapter's frame, and the next pointer move takes it out again.
- **The highlight bar, ribbon, sidebars and panels are XAML over the WebView2**, never in the page, as on Mac. They draw over it without trouble, as the cover crossfade in phase 2 already did.
- **A list's own colours are the theme's ink, never the accent.** The contents and highlights use a ListView with its selection, hover and press brushes replaced and its selection pill turned off. Each opening makes a new list, so the colours are right from the start.
- **A ListView can't take the keyboard until its rows exist.** The sidebars hand it over once the list has loaded, at low priority, so the arrows, Enter and Esc work straight away.
- **Search keeps the keyboard in its field.** The rows are plain elements that never take focus, so a click picks a row rather than closing the box, as on Mac.
- **Found along the way:** with no picture of the last spread to show at launch, the spine's shadow stayed hidden on the first spread until the first restyle. It's now placed again once the book has opened.
- **Done by the self-check rather than by hand:** text is selected by pointing at the middle of the left-hand page, with the page's own selection reporting doing the rest; typing into the page field and search box sets their text directly. Keys go into the page through DevTools, except those meant for the sidebars, which aren't in the page; those go through the window's own key handling.

## Phase 5: Export and import

- [x] `.readmelibrary` format spec written in `docs/`: [readmelibrary-format.md](readmelibrary-format.md)
- [x] `LibraryBundle.cs`, `LibraryExporter.cs`, `LibraryImporter.cs`, with the Swift tests ported
- [x] Never replace; keep mine or combine; newer format refused whole; size limits match. The question is a `ContentDialog`: Enter is Keep Mine, Esc is Cancel
- [x] `pinnedAt` in bundles: a book the import adds keeps its pin; a book already here keeps its own pin state
- [x] Shelf Export, including multi-selection. The Mac's File menu items, Import… and Export Library…, are Ctrl+O (which now takes bundles too) and a "…" menu at the top right of the shelf. Dropping a bundle on the shelf imports it
- [ ] **Done when:** Mac export imports on Windows with highlights, marker and position intact, and the reverse. **Windows side done, the Mac side not yet tried.** `--checks <dir> bundles <fixtures>` exports books read, marked and highlighted, changes the library as another machine's would be, and imports the bundle back through the question, pressing Combine: highlights, marker, further place and pin all come back, and the book reopens on the imported place. The Windows-made golden bundle is read by `GoldenFilesTests.swift` (written, not yet run)

Built on Windows, Nov 13, 2026. `Readme.Core` gained `LibraryBundle.cs`, `LibraryExporter.cs` and `LibraryImporter.cs`, with `LibraryBundleTests.swift`, `LibraryExporterTests.swift` and `LibraryImporterTests.swift` ported: `dotnet test windows/Readme.slnx` runs 231.

### Phase 5 findings

- **The store side was already there.** Phase 1 ported the merge rules (`HighlightStore.Merge`, `MarkerStore.SetIfNone`, `ImportMerge.IsFurther`, `ApplyImported`, `RestorePin`), so this phase is the bundle file and the flow around it.
- **Books now stream in and out of a bundle.** `ZipWriter.Add(name, file)` reads a file twice, once for its checksum and once into the zip, rather than whole into memory, and `ZipReader.CopyTo` writes an entry out a piece at a time. A .NET array stops just short of 2 GB, so this is what lets a book of the Mac's 2 GB limit through. The entries are byte for byte what the Mac writes.
- **One key isn't camelCase:** the manifest's `bookIDs`. It's named by hand; the rest follow the naming policy.
- **A golden bundle now goes the other way too.** `Fixtures/Golden/windows.readmelibrary` is written by `LibraryBundle.Write`, checked byte for byte by `GoldenFilesTests.cs`, and read value by value by a new test in `GoldenFilesTests.swift`. The Mac-made bundle for the Windows tests is still to add.
- **The Mac's File menu has no Windows home,** so Import… and Export Library… live where a Windows shelf would have them: Ctrl+O and the open dialog take `.epub` and `.readmelibrary` together, and a "…" menu at the top right of the shelf has Open… and Export Library…, which is greyed out on an empty shelf. A bundle given on the command line is imported too, ahead of phase 6's file associations.
- **Combining waits for nothing to be in the way.** As on Mac, a book that's open and about to be combined is closed first, once its place is written, and opening a book that's being combined waits for the import to finish, so it opens on the place the import left.
- **A combined book that moves loses its last-spread picture,** as on Mac, so it doesn't flash the old place while opening on the new one.
- **Done by the self-check rather than by hand:** the Keep Mine / Combine question is answered by pressing its Combine button through its automation peer, and exports are saved to a path given in place of the save dialog's.

## Phase 6: Windows integration

- [x] `.epub` and `.readmelibrary` file associations, in `Package.appxmanifest`
- [x] Single instance with file-open redirection (`Program.cs`). `--checks <dir> instance <fixtures>` launches a second copy with a book, a library, nothing, and a path with spaces: each is handed over in about 100 ms and the copy quits, leaving one Readme running
- [x] Auto theme follows Windows: done in phase 2, as Windows' light or dark mode changes. The title bar is now dark in every theme, like the desk and the shelf
- [x] Packaging per the decision above: single-project MSIX, built with `-p:ReadmePackage=true`, x64 and ARM64. A plain build stays unpackaged for development and the self-checks. Identity Name and Publisher are placeholders until Partner Center gives the real ones; see `windows/README.md`
- [x] README's "sandboxed" claim handled for Windows: the Windows wording is in `windows/README.md`, ready for the README's Windows section in phase 8. The README itself is still Mac-only, so it's unchanged
- [ ] CI on `windows-latest` (Core tests, then app tests with WebView2 runtime). **Written, not yet run on GitHub:** `.github/workflows/windows.yml`, run from the Actions tab or the `run-tests` label like the Mac's. Core tests, a book read in the real app by the `read` self-check, then both MSIX packages as artifacts. The app step was run locally as CI runs it
- [x] Signing per the decision above: none in the repo or CI. The Store signs; a test copy is registered with Developer Mode instead
- [ ] **Done when:** double-clicking an EPUB opens it in the running app; installer builds in CI. **First half done:** with the package registered as a test install, opening a book through its file association started Readme on it, and with Readme running, a library and then a book each went to the same window, which came to the front. The packages build locally; CI is still to run

Built on Windows, Nov 13, 2026.

### Phase 6 findings

- **The app has its own `Main` now** (`DISABLE_XAML_GENERATED_MAIN`), since a second launch has to be handed on before any window exists. `AppInstance.FindOrRegisterForKey` takes a key made from the library folder, so a self-check with its own `README_DATA_DIR` never lands in the reader's own Readme. The redirect is waited for with `CoWaitForMultipleObjects`, as an STA thread must, and the second launch calls `AllowSetForegroundWindow` for the first, so the window really does come to the front.
- **A file activation brings its files in the activation, not on the command line.** The first launch takes them from `GetActivatedEventArgs`; a redirected command line is split with `CommandLineToArgvW`, so paths with spaces stay whole.
- **`dotnet build` can make the `.msix`, but not the Store's `.msixupload`.** The wrapper and its symbols package need Visual Studio's own MSBuild (a missing `System.Security.Permissions` and `mspdbcmf.exe`). The Store takes a plain `.msix`, so the package is built `SideloadOnly` without symbols, which keeps CI to the .NET SDK.
- **`IApplicationActivationManager.ActivateForFile` doesn't work for a full-trust app** ("does not support the contract"); a desktop app's file association goes through its ProgID. The test opened files with `ShellExecuteEx` and the ProgID the package registered, which is what Explorer does on a double-click. Readme was the only `.epub` handler on the machine.
- **Documents may be in OneDrive,** as it was here: `Environment.SpecialFolder.MyDocuments` follows it, so the library is in `OneDrive\Documents\Readme`. That was decided in phase 1, and the install docs (phase 8) must say so.
- **The icons are the Mac's,** cropped to the rounded square for the tiles, with a `Readme.ico` for the window and the exe.
- **Not tried:** a real double-click in Explorer, and the Store's own install. Both use the same association.

## Phase 7: Page curl

- [x] `CurlPose.cs`, `SwipeTracker.cs` (end swipe on a pause in deltas), `TurnCoordinator.cs`, all in `Readme.Core/Curl`, with `SpreadCache` beside them: the coordinator and cache are generic over the picture type and the views, so their rules are unit-tested against a fake book
- [x] `SpreadCache.cs` with a second WebView2, an opacity-0 view behind the book
- [x] `CurlView.cs` with Composition strips
- [x] Frame timing check via `CompositionTarget.Rendering`: about 33 UI frames a 0.52 s turn. The curl itself runs on the compositor, so the UI thread's frames only show what else it was doing
- [x] Rapid-turn handling, as on Mac: every press counts, a press that outruns the pictures changes the page with no curl, a held key's repeats are dropped while a turn lands
- [x] If snapshots are too slow: CSS curl fallback, noted here. **Not needed:** at about 200 ms a picture, the cache stays ahead at reading pace; only fast presses outrun it, which change the page without a curl, as on Mac
- [x] **Done when:** curl matches `docs/mockups/open-book-v2.html` and survives held-key rapid turns. `--checks <dir> curl <long.epub>` turns at reading pace (every press curls), backward, 10 presses 120 ms apart (all 10 turn, the first few curl), a key held 2 s (it stops 180 ms after letting go), swipes that turn, fall back, go back and flick, a mouse wheel (nothing), one page across, and Night. Pictured mid-turn and checked by eye against the mockup. **The feel is still for a person to judge,** with a real touchpad: swipes were sent as wheel events

Built on Windows, Nov 14, 2026. `dotnet test windows/Readme.slnx` runs 278.

### Phase 7 findings

- **The curl runs on the compositor.** Every strip's angle, each hinge's shade and the cast shadow are expression animations of one progress value in a `CompositionPropertySet`, written out from `CurlPose`'s maths. A press plays a key-frame animation of that value; fingers set it. So the curl keeps its pace while the UI thread is busy moving the page underneath, which on Mac needed the display link and careful timing.
- **Composition keeps 3D through the tree,** so the strips are a chain of `ContainerVisual`s, each rotated about its left edge, under one perspective matrix about the spine, as Core Animation's transform layers are. Faces hide their backs with `BackfaceVisibility`. Each picture is a whole spread drawn once per face through an inset clip, so nothing is cropped or uploaded twice.
- **Composition's y runs down, Core Animation's up,** so the Mac's negative angles lift the page towards the reader here too, but only without the sign flip a port would expect. The first try had the page sinking away from the reader.
- **Strip edges must be hard.** With the default smoothing, every hinge showed a dotted line of the page beneath; `CompositionBorderMode.Hard` on the strips and faces takes it away, as smoothing only the outer edges does on Mac.
- **The hidden view had no size.** A `WebView2` never given a width has NaN for it, which no "has it changed" comparison catches, so the cache's view laid the book out at 0 by 0 and never reached the reader's place. It's sized on first use now.
- **foliate's slide is off.** The curl, or for less motion a crossfade, turns the page, as on Mac; with no pictures ready the page just changes. The cache's own view never slides, or a picture could catch a page mid-slide.
- **The spine's shadow stays on top,** over the curl: it falls on the pages beneath and on the flat of the turning page, as the Mac draws it on its strips, at the cost of lying on a lifted page too.
- **Swipes come as wheel events** with no beginning or end: a gesture begins after a quiet spell and ends on a 120 ms pause, which includes the touchpad's glide after the fingers lift, so a flick carries on. A mouse wheel's whole 100 or 120 steps along one axis are never a swipe. Fingers going left turn forward, which assumes Windows' default scrolling direction.
- **Coloured fringes** show on the text of a page seen almost edge-on: the pictures keep ClearType's colour smoothing, which only shows when the page is foreshortened. Flat, the picture matches the page.

## Phase 8: Release

- [ ] Store listing or signed installer. **Drafted, not submitted:** `docs/windows-store-listing.md` has the description, features, category, the `runFullTrust` answer, the privacy text and the steps. Submitting needs the owner's Partner Center account and the real package identity
- [x] Windows install docs (including the uninstall note if MSIX): `docs/install-windows.md`. Uninstalling keeps the library in `Documents\Readme` (which may be in OneDrive) and removes the settings
- [x] Release script: `scripts/windows-release.ps1` takes the version from `project.yml` (1.5 build 7 is 1.5.7.0), runs the Core tests and builds both packages into `windows/dist` with checksums; `-Store` refuses the placeholder identity. Steps in `docs/releasing.md`, "Windows"
- [x] README section for Windows, with the privacy line for a full-trust app in place of "sandboxed", and links to the Windows docs
- [ ] **Done when:** someone else installs it from the install docs alone. Needs the Store listing first, and a person
