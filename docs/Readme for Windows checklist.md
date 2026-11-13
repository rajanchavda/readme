# Readme for Windows: progress checklist

Tracks the work in [Readme for Windows phased build plan](Readme%20for%20Windows%20phased%20build%20plan.md). The plan says *what* and *why*; this file says *where we are*.

## How to resume

1. Read **Current state** below, then `git status` and `git log -5` to confirm it.
2. Pick up the first unticked item in the current phase.
3. Tick items as soon as they're done and committed, and update **Current state** before stopping. A ticked item means committed, not just written.

On a new machine, start the first Claude session with "read `docs/Readme for Windows checklist.md`": Claude's memory notes are per machine and don't travel with the repo. Also recreate the personal instructions file that sits above the repo (`~/Documents/personal/CLAUDE.md`), which isn't in git: never use the `gh` CLI, use plain `git`; and keep temporary files in a git-ignored `scratchpad/` folder at the project root.

## Current state

- **Phase:** 4 next. Phases 0 to 3 are done on Windows, apart from the items that need the Mac or a hand
- **Branch:** `feat/windows-phase-0-1`, on `main` at v1.5, pushed (phase 2 is on it too)
- **Last thing done:** phase 3 (Nov 13, 2026): the library shelf. See **Phase 3 findings**. Before that, phases 0 to 2: see their findings
- **Next step:** phase 4, the reading tools. Still to try by hand: dragging books from File Explorer onto the shelf, and reduce motion (phase 2). The Mac items left open (Swift tests, the golden `.readmelibrary`) wait until the Windows app is ready to test against the Mac
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
- [ ] Ship v1 after phase 6 with a slide, or wait for the curl (before phase 6)

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

- [ ] `ReaderToolbar` with auto-hide (`IdleTimer.cs`); cursor hiding
- [ ] `TocSidebar`, `TocProgress.cs`
- [ ] `GoToPageField`
- [ ] `Search.cs`, `SearchBox`
- [ ] `HighlightBar`, `HighlightsSidebar`
- [ ] `MarkerRibbon`
- [ ] `ShortcutsHelp.cs` (Windows key names), `ShortcutsPanel`; every shortcut listed in it, including the Library section (Ctrl+F, Esc)
- [ ] Tooltips, Narrator labels, error sound
- [ ] **Done when:** every row of the shortcut mapping table works

## Phase 5: Export and import

- [ ] `.readmelibrary` format spec written in `docs/`
- [ ] `LibraryBundle.cs`, `LibraryExporter.cs`, `LibraryImporter.cs`
- [ ] Never replace; keep mine or combine; newer format refused whole; size limits match
- [ ] `pinnedAt` in bundles: a book the import adds keeps its pin; a book already here keeps its own pin state
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
