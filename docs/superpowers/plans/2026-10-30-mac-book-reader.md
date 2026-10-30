# Mac Book Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the native Mac EPUB reader in the spec: an Open Book reading view with a natural page curl, and a bookshelf library, that the owner can download and use.

**Architecture:** A SwiftUI/AppKit app. foliate-js paginates and tracks position inside a `WKWebView`. The curl is native: bitmap snapshots of each spread are cut into strips by a chain of Core Animation layers shown over the web view, so a long book costs the animation nothing extra. An offscreen second web view keeps the next and previous spreads ready. The library is a JSON file plus copies of each EPUB in the app's container.

**Tech Stack:** Swift 6, SwiftUI + AppKit, WKWebView, Core Animation, foliate-js (commit `78914aef4466eb960965702401634c2cb348e9b1`, MIT), Swift Testing, XcodeGen (already installed).

**Spec:** `docs/superpowers/specs/2026-10-30-mac-book-reader-design.md`

## Global Constraints

- Apple silicon only, macOS 14 or later.
- Sandboxed, no private APIs, no network access at runtime. No backend or accounts.
- All costs stay at zero: ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) until the owner pays Apple's fee.
- Bundle ID `com.rajanchavda.Readme`, display name `Readme` (working name; keep it in one build setting).
- Never use the `gh` CLI. Plain `git` only. Temporary files go in `scratchpad/`, never `/tmp`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Motion is 200 ms ease-out everywhere except the page curl, which is 520 ms.
- A messy EPUB never crashes the app. No prompts or dialogs while reading or leaving.
- The owner doesn't read code. Every "Owner try" step ends with a plain-language description of what to open and what to look for.

## Review Focus

1. **Turning quickly through a long book:** holding the arrow key in full Moby-Dick stays smooth and lands on the right page. Test in Task 6.
2. **Landing without a jump:** the last frame of the curl matches the real page exactly, including at chapter boundaries and half-empty spreads. Test in Task 4.
3. **First and last page of a book:** turning past either end does nothing, with no blank curl. Test in Task 5.
4. **Changing font size or window size mid-book:** the same paragraph stays on screen. Test in Task 11.
5. **A saved book or position goes bad:** a deleted file or stale position lands in the library or nearest page, with no crash. Test in Task 15.

---

# Milestone 1: The curl trial

Nothing else gets built until the owner has tried this.

### Task 1: Project skeleton

**Files:**
- Create: `project.yml`, `Readme/App/ReadmeApp.swift`, `Readme/Readme.entitlements`, `ReadmeTests/SmokeTests.swift`, `scripts/test.sh`, `docs/mockups/` (copies of the three approved mockups named in the spec)
- Modify: `.gitignore` (add `*.xcodeproj`, `build/`, `DerivedData/`)

**Interfaces:**
- Produces: targets `Readme` and `ReadmeTests`; `scripts/test.sh [Suite]`, which runs `xcodegen generate` and `xcodebuild test`, with `-only-testing:ReadmeTests/<Suite>` when given.

- [ ] **Step 1:** Run `git init -b main`, then commit the existing spec, plan, `.gitignore` and mockup copies as the first commit. Create a branch `build/v1` for the work.
- [ ] **Step 2:** Write `SmokeTests.appIdentity`: `#expect(Bundle(for: BundleToken.self).bundleIdentifier == "com.rajanchavda.Readme")`, using the app bundle.
- [ ] **Step 3:** Run `scripts/test.sh SmokeTests`. Expected: FAIL (no project yet).
- [ ] **Step 4:** Write `project.yml`: macOS 14 target, Swift 6, sandbox on with `com.apple.security.files.user-selected.read-only`, no network entitlements, ad-hoc signing, `CFBundleDocumentTypes` for `org.idpf.epub-container`. Write an app that opens an empty window.
- [ ] **Step 5:** Run `scripts/test.sh SmokeTests`. Expected: PASS.
- [ ] **Step 6:** Commit: `chore: add project skeleton`.

### Task 2: Curl geometry

**Files:**
- Create: `Readme/Curl/CurlPose.swift`
- Test: `ReadmeTests/CurlPoseTests.swift`

**Interfaces:**
- Produces: `enum CurlPose { static let duration = 0.52; static let strips = 28; static let bend = 34.0; static func angles(t: Double, strips: Int = strips, bend: Double = bend) -> [Double]; static func shade(angle: Double) -> Double; static func cast(t: Double) -> Double }`. `angles` returns one cumulative angle per strip, in degrees.

- [ ] **Step 1:** Write `CurlPoseTests`:

```swift
@Test func flatAtStart() { #expect(CurlPose.angles(t: 0).allSatisfy { $0 == 0 }) }
@Test func flatAtEnd() { #expect(CurlPose.angles(t: 1).allSatisfy { $0 == -179.5 }) }
@Test func straightAtMidpoint() { #expect(CurlPose.angles(t: 0.5).allSatisfy { abs($0 + 90) < 0.001 }) }
@Test func outerEdgeLeadsBeforeMidpoint() { let a = CurlPose.angles(t: 0.25); #expect(a.first! == 0); #expect(a.last! < -40) }
@Test func outerEdgeTrailsAfterMidpoint() { let a = CurlPose.angles(t: 0.75); #expect(a.first! == -179.5); #expect(a.last! > -140) }
@Test func shadeIsDarkestEdgeOn() { #expect(abs(CurlPose.shade(angle: -90) - 0.16) < 0.001); #expect(CurlPose.shade(angle: 0) == 0) }
```

- [ ] **Step 2:** Run `scripts/test.sh CurlPoseTests`. Expected: FAIL (not defined).
- [ ] **Step 3:** Implement the same maths as `docs/mockups/open-book-v2.html`:

```
e = t*t*(3-2*t);  b = bend*sin(2*pi*t);  root = -180*e + b;  d = 2*b/(strips-1)
angle[k] = clamp(root - k*d, -179.5, 0)
shade = |sin(angle)| * 0.16;  cast = sin(pi*t)
```

- [ ] **Step 4:** Run `scripts/test.sh CurlPoseTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: add page curl geometry`.

### Task 3: Book rendering in a web view

**Files:**
- Create: `Readme/Web/foliate/` (vendored at the pinned commit, only the modules EPUB needs), `Readme/Web/reader.html`, `Readme/Web/bridge.js`, `Readme/Reader/BookWebView.swift`, `Readme/Reader/BookScheme.swift`, `Readme/Reader/ReaderLocation.swift`, `scripts/make_fixtures.py`, `ReadmeTests/Fixtures/`
- Test: `ReadmeTests/BookWebViewTests.swift`

**Interfaces:**
- Produces: `struct ReaderLocation: Codable, Sendable, Equatable { var cfi: String; var fraction: Double; var chapterTitle: String?; var chapterMinutesLeft: Double; var isAtStart: Bool; var isAtEnd: Bool }`
- Produces: `@MainActor final class BookWebView: NSView { func open(_ url: URL, at cfi: String?) async throws -> ReaderLocation; func next() async -> ReaderLocation?; func previous() async -> ReaderLocation?; func go(toCFI: String) async -> ReaderLocation?; func go(toFraction: Double) async -> ReaderLocation?; func applyStyles(css: String, columns: Int) async; var onRelocate: ((ReaderLocation) -> Void)?; func toc() async -> [TOCEntry] }`
- Produces: `struct TOCEntry: Sendable, Equatable { var title: String; var href: String; var level: Int; var fraction: Double }`
- Produces fixtures from `scripts/make_fixtures.py`: `long.epub` (reflowable, about 40 chapters), `no-cover.epub`, `broken-chapter.epub`, `no-toc.epub`, `scripted.epub`, `drm.epub` (`META-INF/encryption.xml` with a non-font algorithm), `not-an-epub.epub` (random bytes).

- [ ] **Step 1:** Write `BookWebViewTests`:
  - `opensBook`: open `long.epub`, expect `fraction == 0` and `isAtStart`.
  - `nextAdvances`: `next()` returns a larger `fraction` and a different `cfi`.
  - `returnsToSavedPlace`: go to fraction 0.5, save the `cfi`, reopen with `at: cfi`, expect the same `cfi`.
  - `bookScriptsNeverRun`: open `scripted.epub`, whose script sets `document.title` and posts a message; expect neither to reach the app.
  - `brokenChapterStillOpens`: open `broken-chapter.epub`, walk every section with `next()`, expect no thrown error.
  - `missingTOCIsEmpty`: `no-toc.epub` gives `toc() == []`.
- [ ] **Step 2:** Run `scripts/test.sh BookWebViewTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Serve everything through a `WKURLSchemeHandler` on `readme-book://`. Send the header `Content-Security-Policy: default-src 'self' blob: readme-book:; script-src 'self'; connect-src 'self' blob: readme-book:; img-src * blob: data: readme-book:; style-src * 'unsafe-inline'; font-src * blob: data: readme-book:` on `reader.html` (foliate's README requires script blocking by CSP, because WebKit needs `allow-scripts` on its iframes). `bridge.js` drives `<foliate-view>`: `flow="paginated"`, `max-column-count=2`. Take `chapterMinutesLeft` from the `time.section` value of foliate's `relocate` event.
- [ ] **Step 4:** Run `scripts/test.sh BookWebViewTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: render EPUBs with foliate-js`.

### Task 4: Spread snapshots

**Files:**
- Create: `Readme/Curl/SpreadCache.swift`
- Test: `ReadmeTests/SpreadCacheTests.swift`

**Interfaces:**
- Consumes: `BookWebView`, `ReaderLocation`.
- Produces: `@MainActor final class SpreadCache { init(visible: BookWebView); func refresh(around: ReaderLocation) async; func image(for: SpreadSlot) -> CGImage?; func commit(_ direction: TurnDirection) async }`, `enum SpreadSlot { case current, next, previous }`, `enum TurnDirection { case forward, backward }`. Uses one offscreen `BookWebView`, the same size as the visible one and given the same styles, to render neighbours.
- Produces: `enum ImageDiff { static func fractionDifferent(_ a: CGImage, _ b: CGImage) -> Double }`, a test helper.

- [ ] **Step 1:** Write `SpreadCacheTests`:
  - `nextDiffersFromCurrent`: `fractionDifferent(current, next) > 0.01`.
  - `landingMatchesPreview`: after `commit(.forward)`, a fresh snapshot of the visible view has `fractionDifferent(snapshot, previousNextImage) < 0.002`. Run it mid-chapter, across a chapter boundary, and on a half-empty last spread of a chapter.
  - `noPreviousAtStart`: at the start of the book, `image(for: .previous) == nil`; at the end, `image(for: .next) == nil`.
- [ ] **Step 2:** Run `scripts/test.sh SpreadCacheTests`. Expected: FAIL.
- [ ] **Step 3:** Implement with `WKWebView.takeSnapshot`, keeping images at the backing-store scale. Refresh neighbours after each turn without blocking input.
- [ ] **Step 4:** Run `scripts/test.sh SpreadCacheTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: keep neighbouring spreads ready`.

### Task 5: The curl on screen

**Files:**
- Create: `Readme/Curl/CurlView.swift`, `Readme/Reader/TrialReaderWindow.swift`
- Test: `ReadmeTests/CurlViewTests.swift`

**Interfaces:**
- Consumes: `CurlPose`, `SpreadCache`, `TurnDirection`.
- Produces: `@MainActor final class CurlView: NSView { func begin(_ d: TurnDirection, front: CGImage, back: CGImage, beneathLeft: CGImage, beneathRight: CGImage); func setProgress(_ t: Double); func play(from: Double, to: Double, completion: @escaping () -> Void); func end() }`.
- Produces: `@MainActor final class TurnCoordinator { func turn(_ d: TurnDirection) ; var isTurning: Bool }`. A keypress during a turn snaps that turn to its end and starts the next, as in the prototype.

- [ ] **Step 1:** Write `CurlViewTests`:
  - `oneLayerPerStrip`: after `begin`, the chain holds 28 strip layers.
  - `poseMatchesGeometry`: after `setProgress(0.25)`, each strip's relative rotation equals the difference of consecutive `CurlPose.angles(t: 0.25)`, within 0.01 degrees.
  - `noTurnPastEnds`: `TurnCoordinator.turn(.backward)` at book start and `.forward` at book end leave `isTurning == false` and don't change the location.
  - `reduceMotionCrossfades`: with Reduce Motion on, a turn uses a crossfade and creates no strips.
- [ ] **Step 2:** Run `scripts/test.sh CurlViewTests`. Expected: FAIL.
- [ ] **Step 3:** Implement with nested `CATransformLayer`s anchored on their left edge. Each strip has front and back `CALayer`s sharing a bitmap through `contentsRect`, plus shade sublayers. Hide the back faces with `isDoubleSided = false`. Use a perspective `sublayerTransform.m34` of `-1/2400`. Add a cast-shadow gradient layer with `CurlPose.cast`. Wrap updates in `CATransaction` with actions disabled, driven by a display link. Make the trial window: a fixed two-page window opening a file via ⌘O, with arrow keys, space and edge clicks.
- [ ] **Step 4:** Run `scripts/test.sh CurlViewTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: page curl over real book pages`.

### Task 6: Finger-following swipe

**Files:**
- Create: `Readme/Curl/SwipeTracker.swift`
- Modify: `Readme/Curl/CurlView.swift`, the `TurnCoordinator` file
- Test: `ReadmeTests/SwipeTrackerTests.swift`, `ReadmeTests/RapidTurnTests.swift`

**Interfaces:**
- Produces: `struct SwipeTracker { init(pageWidth: Double); mutating func began() ; mutating func changed(deltaX: Double) -> Double; mutating func ended(velocityX: Double) -> SwipeOutcome }`, with `enum SwipeOutcome { case commit, cancel }`. `changed` returns curl progress from 0 to 1.

- [ ] **Step 1:** Write `SwipeTrackerTests`:
  - `followsFingers`: a swipe of half the page width gives progress 0.5.
  - `clampsAtEnds`: a swipe of twice the page width gives progress 1, and a reverse swipe gives 0.
  - `commitsPastHalfway`: release at 0.6 with no velocity gives `.commit`.
  - `fallsBackBeforeHalfway`: release at 0.3 with no velocity gives `.cancel`.
  - `flickCommits`: release at 0.2 with velocity over 600 points per second gives `.commit`.
  - `reverseFlickCancels`: release at 0.7 with reverse velocity over 600 gives `.cancel`.
- [ ] **Step 2:** Write `RapidTurnTests.heldKeyLandsCorrectly`: fire 30 forward turns 50 ms apart in `long.epub`, then expect the final location to equal 30 spreads ahead, with `SpreadCache.image(for: .current)` matching the visible view.
- [ ] **Step 3:** Run `scripts/test.sh SwipeTrackerTests` and `scripts/test.sh RapidTurnTests`. Expected: FAIL.
- [ ] **Step 4:** Implement. Read `scrollWheel` events with `phase` and `momentumPhase`, ignoring momentum. Finish from the release point with the remaining fraction of 520 ms. If the neighbouring spread isn't ready when a swipe starts, wait for it and don't start the curl.
- [ ] **Step 5:** Run both suites. Expected: PASS.
- [ ] **Step 6:** Commit: `feat: page follows two-finger swipe`.

### Task 7: Trial build and the owner's decision

**Files:**
- Create: `Readme/Curl/CurlFrameMonitor.swift`, `scripts/build_app.sh`, `docs/curl-trial.md`

**Interfaces:**
- Produces: `scripts/build_app.sh`, which builds `build/Readme.app`. `CurlFrameMonitor` logs the longest frame and missed-frame count for each turn through `os_log`.

- [ ] **Step 1:** Download Moby-Dick from `https://www.gutenberg.org/ebooks/2701.epub3.images` into a new folder in `scratchpad/`.
- [ ] **Step 2:** Run the build, open the book, turn 100 pages by key and 20 by swipe, and read the monitor's output. Expected: fewer than 1% missed frames at the display's refresh rate.
- [ ] **Step 3:** If it misses that bar, try the spec's simpler curl: first drop shading updates, then go to 14 strips, and measure again. If swipe tracking alone is the problem, fall back to a swipe that plays the curl. Record results in `docs/curl-trial.md`.
- [ ] **Step 4: Owner try (STOP HERE).** Open `build/Readme.app`, choose ⌘O and pick Moby-Dick. Tell the owner to turn pages with the arrow keys and the two-finger swipe, including stopping halfway and letting the page fall back. Ask: "Is this as natural as the prototype?" Report any simplification made. Don't start Milestone 2 until the owner says yes. If the curl still isn't good enough, stop and let the owner choose what's next, per the spec.
- [ ] **Step 5:** Commit: `chore: curl trial build and results`.

---

# Milestone 2: The reading experience

### Task 8: Themes, fonts and page layout

**Files:**
- Create: `Readme/Reader/ReaderSettings.swift`, `Readme/Reader/ReadingCSS.swift`, `Readme/Reader/SpreadLayout.swift`, `Readme/Web/fonts/` (EB Garamond, Literata)
- Test: `ReadmeTests/ReaderSettingsTests.swift`

**Interfaces:**
- Produces: `enum ThemeChoice: String, Codable { case auto, paper, sepia, night }`, `enum Theme { case paper, sepia, night }`, `enum BookFont: String, Codable, CaseIterable { case ebGaramond, literata, newYork }`
- Produces: `struct ReaderSettings: Codable, Equatable { var theme: ThemeChoice = .auto; var font: BookFont = .ebGaramond; var fontSize: Double = 18; var lineWidth: LineWidth = .regular; static func load(_: UserDefaults) -> Self; func save(_: UserDefaults); func resolvedTheme(systemIsDark: Bool) -> Theme }`
- Produces: `enum LineWidth: String, Codable, CaseIterable { case narrow, regular, wide }`
- Produces: `enum ReadingCSS { static func css(_: ReaderSettings, theme: Theme, fullscreen: Bool) -> String }`, `struct ThemeColors { page, ink, soft, desk, spine: NSColor }`, `static func colors(_: Theme) -> ThemeColors`
- Produces: `enum SpreadLayout { static func columns(windowWidth: Double, fontSize: Double, lineWidth: LineWidth) -> Int }`

- [ ] **Step 1:** Write `ReaderSettingsTests`:
  - `defaults`: font `.ebGaramond`, theme `.auto`.
  - `autoFollowsSystem`: `resolvedTheme(systemIsDark: true) == .night`, and false gives `.paper`.
  - `explicitThemeWins`: `.sepia` stays `.sepia` in dark mode.
  - `cssValues`: CSS contains `line-height: 1.55`, `hyphens: auto` and `text-align: justify`; Paper's page colour is `#F8F5EE`; Sepia's is `#EFE0C4`; Night's is `#26272A`, with ink `#BDB9AF`.
  - `fullscreenTextIsLarger`: the fullscreen CSS sets a font size one third larger.
  - `twoPagesWhenWide`: `columns(windowWidth: 1200, fontSize: 18, lineWidth: .regular) == 2`.
  - `onePageWhenNarrow`: `columns(windowWidth: 700, fontSize: 18, lineWidth: .regular) == 1`.
  - `largeTextDropsToOnePage`: `columns(windowWidth: 1000, fontSize: 32, lineWidth: .regular) == 1`.
- [ ] **Step 2:** Run `scripts/test.sh ReaderSettingsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Two columns are allowed only if each holds at least 45 characters at the current size (estimate 0.42 em per character). New York uses `ui-serif`. Desk colours: Paper `#3A332C`, Sepia `#4A3A28`, Night `#17181A`. Styles applied to the web view must also go to the offscreen one, then refresh `SpreadCache`.
- [ ] **Step 4:** Run `scripts/test.sh ReaderSettingsTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: themes, fonts and page layout`.

### Task 9: Reading window and quiet toolbar

**Files:**
- Create: `Readme/Reader/ReaderWindowController.swift`, `Readme/Reader/ReaderToolbar.swift`, `Readme/Reader/IdleTimer.swift`
- Modify: delete `Readme/Reader/TrialReaderWindow.swift`
- Test: `ReadmeTests/IdleTimerTests.swift`, `ReadmeTests/ReaderCommandsTests.swift`

**Interfaces:**
- Consumes: `ReaderSettings`, `ReadingCSS`, `SpreadLayout`, `TurnCoordinator`, `ReaderLocation`.
- Produces: `struct IdleTimer { var delay = 1.6; mutating func activity(at: TimeInterval); func isAwake(at: TimeInterval) -> Bool }`
- Produces: `@MainActor final class ReaderWindowController: NSWindowController { func open(_ book: Book, at: String?) async; var onShowLibrary: (() -> Void)? }`. `Book` is defined in Task 12, so until then this takes a URL.
- Produces: `enum ReaderCommand: CaseIterable { case biggerText, smallerText, toggleTOC, toggleFullscreen, showLibrary }`, each with its key equivalent.

- [ ] **Step 1:** Write tests:
  - `IdleTimerTests`: awake straight after activity, asleep 1.6 s later, and activity wakes it again.
  - `ReaderCommandsTests.shortcuts`: `biggerText` is ⌘+, `smallerText` is ⌘−, `toggleTOC` is ⌘T, `toggleFullscreen` is ⌃⌘F, `showLibrary` is ⌘L.
  - `ReaderCommandsTests.plainFTogglesFullscreen`: an `f` key with no modifiers maps to `toggleFullscreen`.
  - `ReaderCommandsTests.fontSizeLimits`: size stays within 12 to 40.
- [ ] **Step 2:** Run both suites. Expected: FAIL.
- [ ] **Step 3:** Implement to match `docs/mockups/open-book-v2.html`: desk surface, spine shadow overlay, toolbar with blur (themes including Auto, fonts, size, line width, time left, table of contents, library, fullscreen), and the hairline progress bar. Toolbar eases in and out over 200 ms. Hide the title bar, showing traffic lights only on hover. In fullscreen, hide the cursor while idle. Save the window frame with `setFrameAutosaveName`. Themes animate over 200 ms, with no flash. Clicks on the outer page edges turn pages; text in the middle stays selectable.
- [ ] **Step 4:** Run both suites. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: reading window and quiet toolbar`.

### Task 10: Table of contents

**Files:**
- Create: `Readme/Reader/TOCSidebar.swift`, `Readme/Reader/TOCProgress.swift`
- Test: `ReadmeTests/TOCProgressTests.swift`

**Interfaces:**
- Consumes: `TOCEntry`, `BookWebView.toc()`, `BookWebView.go(toFraction:)`.
- Produces: `enum TOCState { case read, current, unread }`, `enum TOCProgress { static func states(entries: [TOCEntry], fraction: Double) -> [TOCState] }`

- [ ] **Step 1:** Write `TOCProgressTests`: entries at 0, 0.5 and 0.8 with fraction 0.6 give `[.read, .current, .unread]`; fraction 0 gives the first as `.current`; an empty list gives an empty result.
- [ ] **Step 2:** Run `scripts/test.sh TOCProgressTests`. Expected: FAIL.
- [ ] **Step 3:** Implement a slide-in sidebar with `NSVisualEffectView`, toggled by ⌘T, easing over 200 ms. Read chapters are dimmed and the current one is marked quietly. Clicking a chapter closes the sidebar and goes there without a curl. For a book with no table of contents, the toggle does nothing.
- [ ] **Step 4:** Run `scripts/test.sh TOCProgressTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: table of contents sidebar`.

### Task 11: Exact position memory

**Files:**
- Create: `Readme/Library/PositionStore.swift`
- Test: `ReadmeTests/PositionStoreTests.swift`, `ReadmeTests/PositionStabilityTests.swift`

**Interfaces:**
- Consumes: `ReaderLocation`, `BookWebView`.
- Produces: `actor PositionStore { init(directory: URL); func save(_: ReaderLocation, bookID: String); func location(bookID: String) -> ReaderLocation?; func remove(bookID: String) }`. Writes are atomic.

- [ ] **Step 1:** Write `PositionStoreTests`: `roundTrip`; `survivesRestart` (a new store on the same directory reads it back); `corruptFileIsIgnored` (garbage in the file gives `nil`, no throw).
- [ ] **Step 2:** Write `PositionStabilityTests`, using `long.epub` at fraction 0.5 and the first visible text of the spread as the marker: after font size 18 to 26, after line width change, after one to two columns, and after a window resize, the marker text is still on the visible spread.
- [ ] **Step 3:** Run both suites. Expected: FAIL.
- [ ] **Step 4:** Implement. Save on each `onRelocate`. For layout changes, capture the start-of-spread CFI first and `go(toCFI:)` afterwards. Don't save the intermediate locations produced while the layout changes.
- [ ] **Step 5:** Run both suites. Expected: PASS.
- [ ] **Step 6:** Commit: `feat: remember exact reading position`.

---

# Milestone 3: The library

### Task 12: Importing books

**Files:**
- Create: `Readme/Library/Book.swift`, `Readme/Library/LibraryStore.swift`, `Readme/Library/BookImporter.swift`
- Test: `ReadmeTests/BookImporterTests.swift`, `ReadmeTests/LibraryStoreTests.swift`

**Interfaces:**
- Produces: `struct Book: Codable, Identifiable, Equatable, Sendable { var id: String /* SHA-256 of file */; var title: String; var author: String?; var fileName: String; var hasCover: Bool; var addedAt: Date; var lastReadAt: Date?; var chapterTitle: String?; var chapterMinutesLeft: Double? }`
- Produces: `@MainActor final class LibraryStore: ObservableObject { @Published private(set) var books: [Book]; init(directory: URL); var current: Book? ; var others: [Book]; func add(_: Book); func remove(id: String); func markRead(id: String, location: ReaderLocation); func fileURL(for: Book) -> URL; func coverURL(for: Book) -> URL }`
- Produces: `enum ImportError: Error, Equatable { case notAnEPUB, copyProtected, unreadable }`, `@MainActor struct BookImporter { func importBook(from: URL) async throws -> Book; func importAll(_: [URL]) async -> [Result<Book, ImportError>] }`

- [ ] **Step 1:** Write `BookImporterTests`:
  - `importsAndCopies`: importing `long.epub` puts a copy in the container, and the original is untouched.
  - `readsMetadata`: title and author match the fixture.
  - `sameBookTwiceIsOneBook`: importing twice leaves one `Book`.
  - `rejectsDRM`: `drm.epub` throws `.copyProtected` and adds nothing. Font obfuscation algorithms alone are not treated as DRM.
  - `rejectsJunk`: `not-an-epub.epub` throws `.notAnEPUB`.
  - `brokenButOpenableImports`: `broken-chapter.epub` and `no-cover.epub` both import, the latter with `hasCover == false`.
  - `dropOfManyKeepsGoing`: `importAll` of good, junk and good gives two books and one failure.
- [ ] **Step 2:** Write `LibraryStoreTests`:
  - `currentIsMostRecentlyRead`, `othersSortedByRecency` (books never read sort by `addedAt`), `noReadBooksMeansNewestIsCurrent`.
  - `removeDeletesCopyAndPosition`, `corruptLibraryFileStartsEmpty`.
- [ ] **Step 3:** Run both suites. Expected: FAIL.
- [ ] **Step 4:** Implement. Check for DRM by reading `META-INF/encryption.xml` before opening. Get metadata and the cover with a hidden `BookWebView`. Save the cover as PNG. The library file is `library.json` in Application Support, written atomically.
- [ ] **Step 5:** Run both suites. Expected: PASS.
- [ ] **Step 6:** Commit: `feat: import books into the library`.

### Task 13: Covers

**Files:**
- Create: `Readme/Library/GeneratedCover.swift`, `Readme/Library/BookCoverView.swift`
- Test: `ReadmeTests/GeneratedCoverTests.swift`

**Interfaces:**
- Produces: `struct CoverPalette: Equatable { var background: Color; var ink: Color }`, `enum GeneratedCover { static let palettes: [CoverPalette]; static func palette(for book: Book) -> CoverPalette }`
- Produces: `struct BookCoverView: View { init(book: Book, width: CGFloat, library: LibraryStore) }`, fixed at a 2:3 ratio.

- [ ] **Step 1:** Write `GeneratedCoverTests`: `stable` (same book, same palette, across launches, so no `hashValue`); `spread` (20 varied titles use at least 5 palettes); `readable` (every palette's ink-to-background contrast is at least 4.5:1); `missingAuthorIsFine` (a book with no author renders without a crash).
- [ ] **Step 2:** Run `scripts/test.sh GeneratedCoverTests`. Expected: FAIL.
- [ ] **Step 3:** Implement using the 12 colour pairs in `docs/mockups/library-v1.html`, with Fraunces (bundled) for the title and EB Garamond italic for the author, and the spine highlight from the mockup. Real covers fill the 2:3 frame. A cover image that won't load falls back to the generated one.
- [ ] **Step 4:** Run `scripts/test.sh GeneratedCoverTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: book covers`.

### Task 14: The bookshelf

**Files:**
- Create: `Readme/Library/ShelfLayout.swift`, `Readme/Library/LibraryView.swift`, `Readme/Library/CurrentBookShelf.swift`, `Readme/Library/ShelfRow.swift`
- Test: `ReadmeTests/ShelfLayoutTests.swift`

**Interfaces:**
- Consumes: `LibraryStore`, `BookImporter`, `BookCoverView`.
- Produces: `enum ShelfLayout { static func rows<T>(_: [T], width: CGFloat, coverWidth: CGFloat = 112, gap: CGFloat = 22, inset: CGFloat = 54) -> [[T]]; static func emptyRowCount(height: CGFloat) -> Int }`
- Produces: `struct LibraryView: View { init(library: LibraryStore, importer: BookImporter, onOpen: @escaping (Book) -> Void) }`

- [ ] **Step 1:** Write `ShelfLayoutTests`: at a width of 980, 12 books give rows of 6 and 6; 7 books give 6 and 1; 0 books give no rows; a narrow window of 400 gives at least 1 per row; `emptyRowCount` keeps at least one empty shelf visible below the top one.
- [ ] **Step 2:** Run `scripts/test.sh ShelfLayoutTests`. Expected: FAIL.
- [ ] **Step 3:** Implement to match `docs/mockups/library-v1.html`: the current book on its own shelf with "CONTINUE READING", title, author, chapter and time left; shelves below; hover lift over 200 ms ease-out. First open has the dashed outline, "Drop a book here" and "Any EPUB file will do." A dropped book settles onto the shelf with a soft animation. Dropping works anywhere in the window. Right-click offers Remove. A failed import shows a quiet message on the shelf that fades by itself, with a kind line for each `ImportError`, and never a modal dialog. For `copyProtected`: "This book is copy-protected, so it can't be opened here."
- [ ] **Step 4:** Run `scripts/test.sh ShelfLayoutTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat: bookshelf library`.

### Task 15: Launch, and getting between the two

**Files:**
- Create: `Readme/App/AppCoordinator.swift`, `Readme/App/LaunchRoute.swift`, `Readme/Library/LastSpreadCache.swift`
- Modify: `Readme/App/ReadmeApp.swift`, `Readme/Reader/ReaderWindowController.swift` (take `Book`)
- Test: `ReadmeTests/LaunchRouteTests.swift`, `ReadmeTests/StaleBookTests.swift`

**Interfaces:**
- Consumes: `LibraryStore`, `PositionStore`, `ReaderWindowController`, `LibraryView`, `BookImporter`.
- Produces: `enum LaunchRoute: Equatable { case library, read(Book, cfi: String?); static func resolve(library: LibraryStore, positions: [String: ReaderLocation], fileExists: (URL) -> Bool) -> LaunchRoute }`

- [ ] **Step 1:** Write `LaunchRouteTests`: no books gives `.library`; books but none ever opened gives `.library`; a last-read book gives `.read` with its saved CFI; a last-read book whose file is gone gives `.library`.
- [ ] **Step 2:** Write `StaleBookTests`: a saved CFI that no longer resolves opens at the saved `fraction`; a book whose file was deleted is dropped from the library on launch, with no crash; `open(_:at:)` on a file replaced by junk returns to the library.
- [ ] **Step 3:** Run both suites. Expected: FAIL.
- [ ] **Step 4:** Implement. On launch to a book, show the saved last-spread bitmap straight away, then swap to the live web view with a short crossfade, so there's no spinner. Write that bitmap on each turn's refresh, at most once a second. ⌘L and the toolbar button go to the library. Handle `application(_:open:)` for Dock drops: import and open the book, or show the quiet message. Closing the window leaves the app running, and clicking the Dock icon reopens it where it was.
- [ ] **Step 5:** Run both suites, then the whole suite with `scripts/test.sh`. Expected: PASS.
- [ ] **Step 6:** Commit: `feat: launch straight back into the book`.
- [ ] **Step 7: Owner try.** Open `build/Readme.app` and walk through the four moments: first open, drop a book, read, close mid-sentence, reopen. Ask what feels wrong, and fix it before Milestone 4.

---

# Milestone 4: Getting it to people

### Task 16: Download package

**Files:**
- Create: `scripts/package.sh`, `docs/install.md`, `THIRD_PARTY_NOTICES.md`, `Readme/Resources/AppIcon.icon` (or asset catalog)
- Test: `scripts/check_release.sh`

**Interfaces:**
- Produces: `build/Readme.dmg`.

- [ ] **Step 1:** Write `scripts/check_release.sh`, which fails unless: `codesign -d --entitlements -` shows the sandbox on and no network entitlements; `lipo -archs` shows `arm64`; `LSMinimumSystemVersion` is `14.0`; and `THIRD_PARTY_NOTICES.md` names foliate-js, zip.js, EB Garamond, Literata and Fraunces.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Confirm each bundled font's and library's licence allows commercial shipping, and include their licence text in the notices. Stop and tell the owner if any doesn't. Write `package.sh` using `hdiutil`, and add a simple app icon. Write `docs/install.md`: plain steps for a reader to open the app the first time through System Settings, Privacy & Security, "Open Anyway".
- [ ] **Step 4:** Run `scripts/package.sh && scripts/check_release.sh`. Expected: PASS.
- [ ] **Step 5:** Commit: `chore: package the app for download`.
- [ ] **Step 6: Owner try.** Give the owner `build/Readme.dmg` and `docs/install.md`, and have them install it from the DMG as a tester would. Tell them what remains for later: paying Apple's fee, choosing a final name, and hosting the file on their website.
