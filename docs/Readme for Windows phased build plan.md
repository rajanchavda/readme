# Readme for Windows: phased build plan

Nov 11, 2026 · @Rajan

## Summary

Build a separate native Windows app in C# with WinUI 3 and WebView2, in a `windows/` folder of the same repo, and leave the Swift app untouched. The Windows app reuses `Readme/Web/` (foliate-js, `bridge.js`, fonts) with one small Windows hook added, and re-implements the roughly 10,100 lines of Swift around it, using the Swift code as the spec.

The work runs as a short spike (phase 0) followed by 8 phases. A usable reader exists after phase 4, feature parity after phase 6, and the page curl lands in phase 7 so it can't block a first release.

- **Reused as-is:** the web layer (about 840 lines of our own JS plus foliate), the 24 EPUB fixtures, the JSON store shapes, the `.readmelibrary` format, the HTML mockups.
- **Translated:** stores, EPUB inspection, import and export, layout maths, swipe and curl maths. About 2,000 lines of pure logic that map almost line for line to C#.
- **Rebuilt:** windowing, toolbar, sidebars, shelf, web view host, curl rendering, packaging. This is where most of the effort goes.

## Stack and project layout

C# on .NET with WinUI 3 (Windows App SDK) for the UI and WebView2 for the book, packaged as MSIX by default, for x64 and arm64.

| Need | macOS today | Windows choice |
| --- | --- | --- |
| UI framework | AppKit, some SwiftUI | WinUI 3 (XAML + C#) |
| Book rendering | WKWebView | WebView2 |
| Serving book files | `WKURLSchemeHandler` (`readme-book://`) | Custom scheme registration + `WebResourceRequested` |
| Page to app messages | `webkit.messageHandlers.readme` | `chrome.webview.postMessage` + `WebMessageReceived` |
| Page snapshots | `takeSnapshot` | `CapturePreviewAsync` |
| Curl animation | Core Animation layers | Composition API visuals |
| Zip and hashing | Compression, CryptoKit | `System.IO.Compression`, `System.Security.Cryptography` |
| JSON | Codable | `System.Text.Json` |
| Generated covers | CoreText, CoreGraphics | Win2D |
| Settings | UserDefaults | A `settings.json` in the app data folder |
| Tests | XCTest | MSTest |
| Build and CI | XcodeGen, macOS runner | `dotnet` / MSBuild, Windows runner |

Project layout, all under `windows/`:

- `Readme.Core/`: a plain class library with no UI references. Stores, models, EPUB inspection, zip, bundle import and export, layout and swipe maths.
- `Readme.App/`: the WinUI 3 app. Windows, controls, web view host, curl, shelf.
- `Readme.Core.Tests/` and `Readme.App.Tests/`: MSTest projects; the app tests use the WinUI unit test app template, which gives tests a XAML UI thread. Fixtures are linked from `ReadmeTests/Fixtures/`, not copied.
- The web folder is linked from `Readme/Web/` in the project file, so both apps ship the same files and the Mac build doesn't change.

### What the web view host must do

Five behaviours of `BookWebView` and the reader window that the Windows host has to reproduce. Each is easy to miss because WKWebView and WebView2 differ.

| Behaviour | macOS today | Windows approach |
| --- | --- | --- |
| Books can't call out to the network | A content rule list blocks remote loads; `open` fails if it can't be installed | Answer every `http`, `https` and `ws` request with a block in `WebResourceRequested`, and cancel navigations and new windows. Confirm in the spike that sockets are covered; the CSP's connect-src should already stop them. Refuse to open a book if the filter isn't in place |
| Nothing persists between sessions | Non-persistent data store | In-private mode on the controller options, with the user data folder in app data |
| Keys work after clicking the page | A local key monitor, because the web view takes keys | XAML keyboard accelerators don't fire while WebView2 has focus. Listen for `keydown` on each section document, in the per-document load hook bridge.js already uses for selections, and post it to the app; keep XAML accelerators for when focus is elsewhere |
| Swipes over the book | A local scroll monitor, because the web view takes scrolling | Same problem. Listen for `wheel` in the same hook and post the deltas |
| The page is not a browser | Not needed in WKWebView | Turn off browser accelerator keys (Ctrl+F, Ctrl+P, F5), the context menu, dev tools, zoom, pinch zoom and swipe navigation |

Both listeners go in `bridge.js` and switch on only when the WebView2 host is present, so the file stays shared and the Mac app behaves as before. This avoids relying on script injection into foliate's sandboxed frames.

## Phases

Each phase ends with something you can run and check. Phases 1 to 4 give a usable reader; do them in order. Phases 5 and 6 can swap.

| # | Phase | What gets built | Done when |
| --- | --- | --- | --- |
| 0 | Spike | Empty WinUI 3 window hosting WebView2, serving `reader.html` over `readme-book://app/`, opening one fixture, with remote loads blocked and keys forwarded from the page. Add the message shim to `bridge.js`. | `long.epub` renders as a two-page spread and the `ready` and `relocate` messages reach C#; an arrow key pressed after clicking the page reaches C#; the remote-image fixture makes no network request; and a second, never-shown WebView2 opens a book and returns a snapshot. |
| 1 | Core library | `Readme.Core`: models, the four stores, `EPUBInspector`, zip reader and writer, layout maths. Tests ported alongside. | Core tests pass, including the 8 DRM fixtures and the junk-file ones. |
| 2 | Reader basics | Reader window, keyboard page turns with a plain slide or fade, themes, fonts, text size, line width, resume position, full screen, the one-page layout for narrow windows, and the reduce-motion setting. | You can read a whole book, quit, and reopen on the same page. |
| 3 | Library shelf | Shelf UI, file picker and drag-and-drop import, real and generated covers, remove book, last-spread placeholder. | Import 5 books, see covers, open and switch between them. |
| 4 | Reading tools | Toolbar with auto-hide, contents sidebar, Go to Page, search box, highlights with bar and sidebar, page marker ribbon, shortcuts panel. | Every row of the README shortcuts table works under its Windows mapping (table below). |
| 5 | Export and import | `.readmelibrary` export, import and merge, with the same "never replace" rule. | A library exported on Mac imports on Windows with highlights, marker and position intact, and the reverse. |
| 6 | Windows integration | `.epub` and `.readmelibrary` file associations, single instance with file-open redirection, Auto theme following Windows, packaging (MSIX or unpackaged, see open decisions), CI on a Windows runner, signing (see open decisions). | Double-clicking an EPUB opens it in the running app; installer builds in CI. |
| 7 | Page curl | Spread snapshot cache, strip-based curl on Composition visuals, touchpad swipe tracking, rapid-turn handling. | Curl matches `docs/mockups/open-book-v2.html` and holds up to held-key rapid turns. |
| 8 | Release | Store listing or signed installer, install docs, release script, README section for Windows. | A stranger can install it by following the install docs alone. |

Phase 0 is deliberately a throwaway spike. It proves the riskiest assumptions (foliate paginating correctly in Chromium, keys and swipes getting past the web view, and a hidden web view that paints) before anything else is built on them.

### Shortcut mapping

Swapping Cmd for Ctrl works for most commands but not all. The Windows column is a proposal that follows Windows conventions.

| Command | Mac | Windows |
| --- | --- | --- |
| Next and previous page | Arrows, Space | Same |
| Bigger and smaller text | Cmd + and Cmd - | Ctrl + and Ctrl - |
| Contents | Cmd T | Ctrl T |
| Highlights | Shift Cmd H | Ctrl Shift H |
| Mark this page | Cmd D | Ctrl D |
| Go to marker | Shift Cmd D | Ctrl Shift D |
| Go to page | Cmd G | Ctrl G |
| Find | Cmd F | Ctrl F |
| Library | Cmd L | Ctrl L |
| Go to start and end | Cmd Up and Cmd Down | Ctrl Home and Ctrl End |
| Full screen | Ctrl Cmd F | F11 |
| Keyboard shortcuts | ? or Cmd / | ? or Ctrl / |

Several of these (Ctrl F, G, T, L, D, plus and minus) are browser shortcuts inside WebView2, so they only reach the app once browser accelerator keys are turned off.

### Smaller items to carry over

None of these is large, but each is in the Mac app today and easy to leave out.

- Window size and position remembered between launches (phase 2).
- Stores flushed before the app closes, so the last position is never lost (phase 2).
- Shelf right-click menu with Export and Remove, and export of a multi-selection (phases 3 and 5).
- Import failure notices and the "keep mine or combine" question when importing a library (phases 3 and 5).
- Tooltips and screen-reader labels; Narrator in place of VoiceOver (phase 4).
- Cursor and toolbar hiding while reading, and the error sound (phase 4).
- The README's "sandboxed" claim: a standard MSIX desktop app is not sandboxed, so drop the claim for Windows or opt into AppContainer (phase 6).

## File map

Every Swift file, its Windows counterpart, and the phase it lands in. "Port" means a near line-for-line translation into `Readme.Core`; "rebuild" means new code in `Readme.App` against the same behaviour.

### App

| Swift file | Windows counterpart | Work | Phase |
| --- | --- | --- | --- |
| `ReadmeApp.swift` | `App.xaml.cs`: launch, key handling routed from the page, XAML accelerators as backup, file activation | Rebuild | 2, 6 |
| `AppCoordinator.swift` | `AppCoordinator.cs`: owns the stores and the window, routes opens and imports | Rebuild | 2 |
| `LaunchRoute.swift` | `LaunchRoute.cs` | Port | 2 |
| `BundledFonts.swift` | Loads the bundled fonts for cover drawing and text measurement | Rebuild, small | 2 |

### Library

| Swift file | Windows counterpart | Work | Phase |
| --- | --- | --- | --- |
| `Book.swift` | `Book.cs` record | Port | 1 |
| `LibraryStore.swift` | `LibraryStore.cs` with `library.json`, `Books/`, `Covers/` | Port | 1 |
| `PositionStore.swift` | `PositionStore.cs` | Port | 1 |
| `HighlightStore.swift` | `HighlightStore.cs` | Port | 1 |
| `MarkerStore.swift` | `MarkerStore.cs` | Port | 1 |
| `EPUBInspector.swift` | `EpubInspector.cs` plus a port of its own zip reader (same read limits, same ZIP64 refusal), so the malformed-file fixtures behave the same. Not `ZipArchive` | Port | 1 |
| `ZipWriter.swift` | `System.IO.Compression.ZipArchive` is the easy route, but port the writer instead: the Mac reader accepts only stored or deflated entries and no ZIP64, so the output must stay inside that | Port | 1 |
| `BookImporter.swift` | `BookImporter.cs`; needs a hidden WebView2, since import opens each book to check it; cover extraction via `BitmapDecoder` | Port, part rebuild | 3 |
| `LastSpreadCache.swift` | `LastSpreadCache.cs`; PNGs from `CapturePreviewAsync` | Port | 3 |
| `GeneratedCover.swift` | `GeneratedCover.cs` drawn with Win2D; same 12 palettes and FNV-1a pick; text is re-measured, so expected sizes in the tests will differ | Rebuild | 3 |
| `BookCoverView.swift` | `BookCover` XAML control | Rebuild | 3 |
| `LibraryView.swift` | `LibraryPage.xaml` | Rebuild | 3 |
| `CurrentBookShelf.swift` | `CurrentBookShelf` XAML control | Rebuild | 3 |
| `ShelfRow.swift` | `ShelfRow` XAML control | Rebuild | 3 |
| `ShelfLayout.swift` | `ShelfLayout.cs` | Port | 3 |
| `ShelfSelection.swift` | `ShelfSelection.cs`; Ctrl and Shift in place of Cmd and Shift | Port | 3 |
| `ShelfDrops.swift` | XAML `DragOver` and `Drop` handlers with `StorageItems` | Rebuild | 3 |
| `LibraryBundle.swift` | `LibraryBundle.cs` | Port | 5 |
| `LibraryExporter.swift` | `LibraryExporter.cs` | Port | 5 |
| `LibraryImporter.swift` | `LibraryImporter.cs` | Port | 5 |

### Reader

| Swift file | Windows counterpart | Work | Phase |
| --- | --- | --- | --- |
| `BookScheme.swift` | `BookScheme.cs`: scheme registration plus a `WebResourceRequested` handler, same CSP header | Rebuild | 0 |
| `BookWebView.swift` | `BookWebView.cs` wrapping WebView2: script calls, messages, snapshots, remote-load blocking, browser features switched off | Rebuild | 0, 2 |
| `ReaderWindowController.swift` | `ReaderPage.xaml.cs`, split into smaller controllers (turning, panels, highlights, layout) | Rebuild | 2, 4 |
| `ReaderCommand.swift` | `ReaderCommand.cs` plus `KeyboardAccelerator` as backup; keys mostly arrive from the page | Port, rebind keys | 2 |
| `ReaderSettings.swift` | `ReaderSettings.cs` saved to `settings.json` | Port | 2 |
| `ReaderLocation.swift` | `ReaderLocation.cs` | Port | 1 |
| `ReadingCSS.swift` | `ReadingCss.cs`; same CSS, font URLs unchanged; re-check its WebKit-specific workarounds (hyphenation, long words, wide tables) under Chromium | Port | 2 |
| `SpreadLayout.swift` | `SpreadLayout.cs` | Port | 2 |
| `BookFrame.swift` | `BookFrame.cs` | Port | 2 |
| `PlaceKeeper.swift` | `PlaceKeeper.cs` | Port | 2 |
| `DeskView.swift` | Root `Grid` of `ReaderPage` (wheel and swipe deltas arrive from the page) | Rebuild | 2 |
| `SpineShadow.swift` | Gradient brush or Composition sprite | Rebuild | 2 |
| `IdleTimer.swift` | `IdleTimer.cs` | Port | 4 |
| `ReaderToolbar.swift` | `ReaderToolbar` XAML control | Rebuild | 4 |
| `TOCSidebar.swift` | `TocSidebar` XAML control (`ListView`) | Rebuild | 4 |
| `TOCProgress.swift` | `TocProgress.cs` | Port | 4 |
| `GoToPageField.swift` | `GoToPageField` XAML control | Rebuild | 4 |
| `Search.swift` | `Search.cs` | Port | 4 |
| `SearchBox.swift` | `SearchBox` XAML control | Rebuild | 4 |
| `HighlightBar.swift` | `HighlightBar` XAML popup | Rebuild | 4 |
| `HighlightsSidebar.swift` | `HighlightsSidebar` XAML control | Rebuild | 4 |
| `MarkerRibbon.swift` | `MarkerRibbon` XAML shape | Rebuild | 4 |
| `ShortcutsHelp.swift` | `ShortcutsHelp.cs` with Windows key names | Port, new labels | 4 |
| `ShortcutsPanel.swift` | `ShortcutsPanel` XAML control | Rebuild | 4 |

### Curl

| Swift file | Windows counterpart | Work | Phase |
| --- | --- | --- | --- |
| `CurlPose.swift` | `CurlPose.cs` | Port | 7 |
| `SwipeTracker.swift` | `SwipeTracker.cs`; same flick threshold logic | Port | 7 |
| `TurnCoordinator.swift` | `TurnCoordinator.cs` | Port, adapt | 7 |
| `SpreadCache.swift` | `SpreadCache.cs`: second WebView2 rendering neighbouring spreads | Rebuild | 7 |
| `CurlView.swift` | `CurlView.cs`: strips as Composition `SpriteVisual`s with 3D transforms | Rebuild | 7 |
| `CurlFrameMonitor.swift` | `CompositionTarget.Rendering` timing check | Rebuild | 7 |

### Build, scripts and tests

| macOS item | Windows counterpart | Phase |
| --- | --- | --- |
| `project.yml`, `Info.plist`, entitlements | `.csproj` files and `Package.appxmanifest` (file types, capabilities) | 0, 6 |
| `scripts/build_app.sh`, `test.sh`, `package.sh`, `release.sh` | PowerShell or `dotnet` equivalents | 6, 8 |
| `.github/workflows/tests.yml`, `release.yml` | Matching jobs on `windows-latest` | 6 |
| `ReadmeTests/*.swift` (48 files, 9,181 lines) | MSTest tests, ported with the code they cover | Each phase |
| Homebrew cask, DMG | Microsoft Store listing, or a signed installer on the release page | 8 |

## Shared contract

Three things are shared between the apps, and each needs one rule so they don't drift.

**1. The web layer.** `Readme/Web/` stays the single copy. Two changes are needed. The first is how the page talks to the app: `bridge.js` posts through `webkit.messageHandlers.readme` in four places. Replace those with one helper that uses the WebKit handler when present and `chrome.webview.postMessage` otherwise. The five message types (`ready`, `relocate`, `link`, `selection`, `highlight`) and their JSON stay identical. The second is the Windows-only key and wheel forwarding described under the web view host.

One difference to design for: Swift awaits page functions with `callAsyncJavaScript`. WebView2's script call doesn't wait for a promise, so async calls on Windows need a request id sent in and the result posted back as a message, or a DevTools-protocol evaluate call, which can await a promise.

**2. On-disk stores.** Same folder shape as under Application Support on Mac, rooted at the app's local data folder (`ApplicationData.Current.LocalFolder` for an MSIX app; Windows redirects a packaged app's writes to a plain `%LOCALAPPDATA%\Readme\` path). One behaviour differs from Mac: uninstalling an MSIX app deletes this folder, so an uninstall removes the library. The install docs should say so and point to Export first.

- `library.json`, `Books/`, `Covers/<id>.png`
- `Highlights/`, `Markers/`, `Positions/` as one JSON file per book
- `LastSpreads/`

Field names must match the Swift `Codable` structs exactly, dates are ISO 8601, and book ids come from the same SHA-256 scheme, so a book has the same id on both platforms. Treat the page number and page count in a saved position as a cache: they come from the engine's pagination, so after a cross-platform import they are stale until the book is next opened. The CFI is what counts.

**3. The `.readmelibrary` bundle.** A zip with `manifest.json` (with `formatVersion`) and `books/<id>/` holding `book.json`, `book.epub`, `highlights.json`, and optional `marker.json` and `position.json`. Write this down as a short spec in `docs/`, and bump `formatVersion` in both apps together.

The import rules are part of the contract and must be ported exactly, since they are what make two-way use between a Mac and a PC safe:

- A book already in the library is never replaced.
- When a bundle holds books already here, the app asks: **keep mine** leaves them untouched; **combine** adds the highlights not here yet, keeps whichever reading place is further along, and keeps this machine's marker if it has one.
- A bundle from a newer format version is refused whole, not half read.
- Size limits match the Mac's: 2 GB per book and 64 MB per notes file, with entries stored uncompressed.

Like a position, a marker also stores a page number from the engine's pagination. Treat it as a cache across platforms; its CFI is what counts.

To enforce all three: commit a few golden files (a `library.json`, a highlights file, one exported `.readmelibrary`) to the shared fixtures, and have both test suites read them. If either app changes a format, the other app's tests fail.

## Risks and open decisions

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Custom scheme under WinUI 3 | Supported since Windows App SDK 1.5 by passing a custom environment when initialising the control. The scheme must be registered with an authority, as secure, and with its own origin allowed, and the CSP's 'self' must resolve to it | Prove it in phase 0. Fallback: serve from a virtual `https://` host with `WebResourceRequested`, and adjust the CSP |
| Chromium vs WebKit pagination | Page counts and breaks may differ, so "page 142" may not be the same page on both | Positions and highlights use CFIs, which are engine-independent. Accept differing page numbers; run all 24 fixtures in phase 0 |
| Snapshots for the curl | `CapturePreviewAsync` is slower than `takeSnapshot`, and a hidden WebView2 may not paint | Phase 7 fallback: do the curl in CSS inside the page, as in `open-book-v2.html` |
| Touchpad swipes | Windows gives horizontal wheel deltas with no begin and end phases | End a swipe on a short pause in deltas; keep `SwipeTracker` maths unchanged |
| "New York" font | It's Apple-only; the CSS falls back to Georgia on Windows | Offer the bundled Fraunces as the third face on Windows |
| Unsigned installer | An unsigned MSIX won't install at all, which is stricter than the Mac's "Open Anyway" | Publish through the Microsoft Store, which re-signs the package, or pay for signing (Azure Artifact Signing or a CA certificate) for direct downloads |
| WinUI 3 learning curve | New framework and language for this codebase | Phase 0 and 1 are low-UI on purpose, so C# comes before XAML |

Three more risks, added on review:

- **Hidden web views arrive early.** Import opens each book in an offscreen web view, so a WebView2 that works without being shown is needed in phase 3, not only for the curl in phase 7. Test it in the phase 0 spike.
- **Mouse wheel vs touchpad.** On Mac only a trackpad gesture turns the page and a mouse wheel does nothing. Windows wheel events don't cleanly tell the two apart, so the behaviour needs a decision.
- **UI tests need the real thing.** 26 of the 48 Swift test files drive a real window and web view. Their Windows versions need the WinUI test app host and the WebView2 runtime on the CI runner, and will be slower to port than the Core tests.

Open decisions:

- [ ] Minimum Windows version: Windows 10 or Windows 11 only?
- [ ] Distribution: Microsoft Store, paid-signed direct download, or both?
- [ ] Ship v1 after phase 6 with a simple page slide, or wait for the curl in phase 7?
- [ ] Freeze Mac features until Windows reaches parity?

* [ ] Mouse wheel: should one notch turn a page on Windows, or do nothing as on Mac?
* [ ] Uninstall deletes the library under MSIX: accept and document, or store the library in Documents instead?

- [ ] Packaging: MSIX, or an unpackaged build with a classic installer? Unpackaged can ship unsigned with a SmartScreen warning, as the Mac build does today, and keeps the library on uninstall. The cost is doing file associations and updates by hand.
