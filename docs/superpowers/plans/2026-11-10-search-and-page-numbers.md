# Search and Page Numbers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dim page number in the corner of every spread, then ⌘F search in a floating box that lists matches with their context and jumps to the one picked.

**Architecture:** The page number is foliate's own page footer (`renderer.feet`), filled in by `bridge.js` on every move. Because it's part of the web page, it's in the curl's pictures and turns with the page. Search runs in `bridge.js` on foliate's `searchMatcher` (from the vendored `search.js`) over the book's linear sections only. Each match comes back as a CFI, an excerpt, a page number and a chapter. The Swift side shows these in a new `SearchBox` view and picks one through the existing `jump`. We don't use `view.search()`, because it draws every match as an annotation, which our `draw-annotation` handler would paint as highlights, and it also searches non-linear sections. Both go against the spec.

**Tech Stack:** Swift 6, AppKit, WKWebView, foliate-js (vendored, commit 78914aef4466eb960965702401634c2cb348e9b1), Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-11-10-search-and-page-numbers-design.md`

## Global Constraints

- macOS 14 or later, Apple silicon only. Swift 6 strict concurrency (`SWIFT_VERSION: "6.0"`).
- `search.js` comes from foliate-js commit `78914aef4466eb960965702401634c2cb348e9b1`, unchanged. It's covered by the existing foliate-js entry in `THIRD_PARTY_NOTICES.md`.
- Run tests with `scripts/test.sh [Suite]`. Regenerate fixtures with `python3 scripts/make_fixtures.py`.
- Search never sets, moves or reads the reading marker.
- Search never leaves marks on the page. Only the picked match glows, for about 2 seconds, and that glow is never saved as a highlight.
- Only linear sections are searched (`section.linear !== 'no'`).
- At least 2 characters before a search runs. Results stop at 500.
- Exact text: `"1 match"`, `"84 matches"`, `"500+ matches, type more to narrow it down"`, `"No matches"`. Row detail: `"142 · The Letter"`, or `"142"` when the chapter has no title.
- Menu item: "Find…", ⌘F, in the Go menu straight after "Go to Page…".
- Everything must work in the paper, sepia and night themes, fullscreen, one and two columns, and with the page curl.
- Commits end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01N1Kwn4qeXtJG1o13EM8EKK
  ```

## Review Focus

1. **Night theme page number.** The footer sits in foliate's shadow DOM, outside the book's CSS, so it starts out black on a dark page. It must take the text colour of the page. Test: `pageNumberTakesThePageInk` (Task 1).
2. **Page number after a font or column change.** foliate rebuilds `feet` on every layout, which wipes the text. The number must be back once the layout settles. Test: `pageNumberSurvivesARestyle` (Task 1).
3. **A new search typed while a long one is still running.** The old one must stop and must not overwrite the new list. Test: `aNewerSearchCancelsTheOlder` (Task 2), plus a check in the controller that a stale reply is dropped (Task 4).
4. **Clicking a row closes the box before the pick lands.** A click moves keyboard focus off the field, and the field ending its edit closes the box. The row click must still go to the match. Test: `clickingARowGoesToIt` (Task 4).
5. **Picking a match while a curl or an earlier jump is still running.** It must go through `jump`, which waits for turns to land, never straight to `book.go`. Test: `pickingAMatchMovesTheSavedPlace` (Task 4), which checks the place is saved like a TOC jump.

---

### Task 1: Page number in the corner

**Files:**
- Modify: `Readme/Web/bridge.js` (the `relocate` listener in `open`, `setLayout`, and `readmeBridge`)
- Modify: `Readme/Reader/BookWebView.swift` (add `pageLabel()`)
- Test: `ReadmeTests/PageNumberTests.swift` (new; use the window and fixture setup from `MarkerBridgeTests`)

**Interfaces:**
- Produces: JS `readmeBridge.pageLabel() -> { text: string, color: string } | null`, which reads the footer cell that holds the number. Swift `struct PageLabel: Decodable, Equatable, Sendable { var text: String; var color: String }` and `func pageLabel() async -> PageLabel?` on `BookWebView`. These are for tests only.

- [ ] **Step 1: Write the failing tests in `PageNumberTests`**

```swift
@Test func pageNumberIsTheSpreadsStartPage() async throws {
    // long.epub, 2 columns, font 18
    let first = try await open()
    #expect(await view.pageLabel()?.text == String(first.page))
    let landed = try #require(await view.go(toPage: 40))
    #expect(await view.pageLabel()?.text == String(landed.page))
    let next = try #require(await view.next())
    #expect(await view.pageLabel()?.text == String(next.page))
}
@Test func pageNumberSurvivesARestyle() async throws {
    _ = try await open(); _ = await view.go(toPage: 40)
    await view.applyStyles(css: css(fontSize: 26), columns: 1); await view.settle()
    #expect(await view.pageLabel()?.text == String(try #require(view.currentLocation).page))
}
@Test func pageNumberTakesThePageInk() async throws {
    // open with ReadingCSS.css(settings, theme: .night, fullscreen: false)
    let label = try #require(await view.pageLabel())
    #expect(label.color == /* computed `color` of the book's <body>, read via evaluateJavaScript on currentDocument */)
    #expect(label.color != "rgb(0, 0, 0)")
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/test.sh PageNumberTests`
Expected: FAIL, because `pageLabel` isn't defined.

- [ ] **Step 3: Show the number in `bridge.js`**

Add `showPageNumber()`. It writes `pageNow()` into the footer cell under the right-hand page: `view.renderer.feet.at(-1)`, or `feet[0]` when `book.dir === 'rtl'`. It clears the other cells. It sets that cell's `style.color` to the computed `color` of `currentDocument().body`, `style.opacity` to `0.35`, and `style.textAlign` to `end`, overriding foliate's centred `.6` style. Call it from the `relocate` listener every time, before the `busy` check, and at the end of `setLayout`. Do nothing when `feet` is null (scrolled flow). Add `pageLabel` to `readmeBridge`, returning the cell's `textContent` and computed `color`.

- [ ] **Step 4: Add `BookWebView.pageLabel()`**, using the existing `call(_:arguments:as:)`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `scripts/test.sh PageNumberTests`, then `scripts/test.sh CurlViewTests` and `scripts/test.sh SpineTests`
Expected: all pass. The curl and spine suites show the footer didn't disturb the pictures or the margins.

- [ ] **Step 6: Owner try.** Build with `scripts/build_app.sh`. Open a book in paper, sepia and night, turn pages slowly, and check that the number curls over with its page.

- [ ] **Step 7: Commit**

```bash
git add Readme/Web/bridge.js Readme/Reader/BookWebView.swift ReadmeTests/PageNumberTests.swift
git commit -m "feat: dim page number in the corner of each spread"
```

---

### Task 2: Search in the page

**Files:**
- Create: `Readme/Web/foliate/search.js` (download it, as below)
- Modify: `scripts/make_fixtures.py` (add `Chapter(linear=...)` and `search_book()`), then regenerate `ReadmeTests/Fixtures/search.epub`
- Modify: `Readme/Web/bridge.js` (add `search`, `flash`, and a shared `fractionInSection`)
- Create: `Readme/Reader/Search.swift` (`SearchMatch`, `SearchOutcome`)
- Modify: `Readme/Reader/BookWebView.swift` (add `search`, `flash`)
- Test: `ReadmeTests/SearchBridgeTests.swift`

**Interfaces:**
- Produces, in JS:
  - `readmeBridge.search(query, limit) -> { matches: [{ cfi, pre, match, post, page, chapter }], isCapped, isCancelled }`
  - `readmeBridge.flash(cfi)`, which returns at once. The glow removes itself after 2 seconds.
- Produces, in Swift (`Search.swift`):
  ```swift
  struct SearchMatch: Codable, Equatable, Sendable { var cfi: String; var pre: String; var match: String; var post: String; var page: Int; var chapter: String? }
  struct SearchOutcome: Equatable, Sendable { var matches: [SearchMatch]; var isCapped: Bool }
  ```
  On `BookWebView`: `func search(_ query: String, limit: Int) async -> SearchOutcome?` returns nil when a newer search cancelled this one, or when no book is open. Also `func flash(_ cfi: String) async`.

- [ ] **Step 1: Vendor `search.js`**

```bash
curl -fL -o Readme/Web/foliate/search.js \
  https://raw.githubusercontent.com/johnfactotum/foliate-js/78914aef4466eb960965702401634c2cb348e9b1/search.js
```
Expected: 130 lines, exporting `searchMatcher` and `search`.

- [ ] **Step 2: Add the `search.epub` fixture**

`Chapter` gets `linear=True`. `package()` writes `linear="no"` on the itemref when it's false. `search_book()` writes `search.epub` with:
- ch1 "The Harbour", with "Elena" twice
- ch2 "The Letter", with "Café Lumière" once and "Elena" once
- ch3 "The Road", with no "Elena"
- `notes`, marked non-linear, with "Elena" and "Zanzibar"

Put each chapter's matches inside ordinary `paragraphs(...)` filler. Call `search_book()` from `main()`. Run `python3 scripts/make_fixtures.py`, and check that `git status` shows only `search.epub` as new among the fixtures.

- [ ] **Step 3: Write the failing tests in `SearchBridgeTests`**

```swift
@Test func findsEveryMatchInTheReadableBook() async throws {   // search.epub
    let outcome = try #require(await view.search("elena", limit: 500))
    #expect(outcome.matches.count == 3)                     // not the one in notes
    #expect(outcome.matches.map(\.chapter) == ["The Harbour", "The Harbour", "The Letter"])
    #expect(outcome.matches.allSatisfy { $0.match.lowercased() == "elena" })
    #expect(outcome.matches.map(\.page) == outcome.matches.map(\.page).sorted())
}
@Test func ignoresCaseAndAccents() async throws {
    #expect(await view.search("CAFE", limit: 500)?.matches.first?.match == "Café")
}
@Test func skipsNonLinearSections() async throws {
    #expect(await view.search("zanzibar", limit: 500)?.matches.isEmpty == true)
}
@Test func stopsAtTheLimit() async throws {                    // long.epub
    let outcome = try #require(await view.search("the", limit: 500))
    #expect(outcome.matches.count == 500); #expect(outcome.isCapped)
}
@Test func aNewerSearchCancelsTheOlder() async throws {        // long.epub
    async let older = view.search("the", limit: 100_000)
    try await Task.sleep(for: .milliseconds(20))
    let newer = await view.search("harbour", limit: 500)
    #expect(await older == nil); #expect(newer?.matches.isEmpty == false)
}
@Test func aMatchsPageIsWhereGoingToItLands() async throws {   // long.epub, 2 columns, font 18
    let match = try #require(await view.search("harbour", limit: 500)?.matches.dropFirst(40).first)
    let landed = try #require(await view.go(toCFI: match.cfi))
    #expect(landed.page <= match.page); #expect(match.page - landed.page <= 3)
}
@Test func searchingNeverMoves() async throws {
    let before = try #require(view.currentLocation)
    _ = await view.search("harbour", limit: 500)
    #expect(view.currentLocation == before)
}
@Test func flashLeavesNoHighlight() async throws {
    // search, go(toCFI:), flash(cfi); immediately an overlay element exists for the range;
    // after 2.5 s it's gone and `view.highlightCFIs` is still empty.
}
```

- [ ] **Step 4: Run them to see them fail**

Run: `scripts/test.sh SearchBridgeTests`
Expected: FAIL, because `search` isn't defined on `BookWebView`.

- [ ] **Step 5: Implement `search` in `bridge.js`**

Import `searchMatcher` from `./foliate/search.js` and `textWalker` from `./foliate/text-walker.js`. Build the matcher with `{ defaultLocale: book.metadata?.language, matchCase: false, matchDiacritics: false, matchWholeWords: false }`.

A module-level `searchGeneration` counter goes up on every call. The loop works through `book.sections` where `linear !== 'no'` and `createDocument` exists. After each `await createDocument()` it checks the counter, and returns `{ matches: [], isCapped: false, isCancelled: true }` if a newer search has started.

Each match is worked out as follows:
- `cfi` is `view.getCFI(index, range)`.
- `pre`, `match` and `post` come from the matcher's `excerpt`.
- `chapter` is `view.getProgressOf(index, range).tocItem?.label?.trim() || null`.
- `page` is `progress.getProgress(index, fractionInSection(range)).location.current + 1`.

`fractionInSection(range)` is the text-before-the-range share of `body.textContent`, taken out of the existing `fractionOf`, which now uses it too.

Stop at `limit` and set `isCapped`. Don't go through `enqueue`, because search must not wait behind page turns.

- [ ] **Step 6: Implement `flash` in `bridge.js`**

Keep a `flashing` CFI. `flash(cfi)` does three things. It deletes any earlier flash. It does nothing if `highlights.has(cfi)`. Otherwise it calls `view.addAnnotation({ value: cfi })` and sets a 2000 ms timer that deletes it.

In the `draw-annotation` listener, when `annotation.value === flashing`, draw with `Overlayer.highlight` in `highlightColor`. Give the returned element a CSS opacity animation from 1 to 0 over its last 600 ms. All other annotations draw as they do now.

- [ ] **Step 7: Add the Swift side.** Create `Search.swift` with the two types. Add `BookWebView.search`, which decodes a private reply struct and maps `isCancelled` to nil, and `BookWebView.flash`.

- [ ] **Step 8: Run the tests to see them pass**

Run: `scripts/test.sh SearchBridgeTests`, then `scripts/test.sh HighlightBridgeTests`
Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add Readme/Web/foliate/search.js Readme/Web/bridge.js Readme/Reader/Search.swift Readme/Reader/BookWebView.swift \
  scripts/make_fixtures.py ReadmeTests/Fixtures/search.epub ReadmeTests/SearchBridgeTests.swift
git commit -m "feat: search the book's text from the page"
```

---

### Task 3: The Find command and what the box says

**Files:**
- Modify: `Readme/Reader/Search.swift` (add `SearchResults`)
- Modify: `Readme/Reader/ReaderCommand.swift` (add `case find`)
- Modify: `Readme/App/ReadmeApp.swift` (add `item(.find)` after `item(.goToPage)` in the Go menu)
- Modify: `Readme/Reader/ReaderWindowController.swift` (the `perform` switch: `case .find: showSearch()`, as a stub for now so the switch compiles)
- Test: `ReadmeTests/SearchResultsTests.swift`, `ReadmeTests/ReaderCommandsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SearchResults {
      static let minimumLength = 2
      static let limit = 500
      static func isSearchable(_ query: String) -> Bool   // trimmed length >= minimumLength
      static func countText(_ outcome: SearchOutcome) -> String
      static func detail(_ match: SearchMatch) -> String
  }
  ```
  Also `ReaderCommand.find`: shortcut `KeyShortcut("f", [.command])`, title `"Find…"`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func searchableNeedsTwoCharacters() {
    #expect(!SearchResults.isSearchable("e")); #expect(!SearchResults.isSearchable(" e "))
    #expect(SearchResults.isSearchable("el"))
}
@Test func countText() {
    #expect(SearchResults.countText(outcome(count: 0)) == "No matches")
    #expect(SearchResults.countText(outcome(count: 1)) == "1 match")
    #expect(SearchResults.countText(outcome(count: 84)) == "84 matches")
    #expect(SearchResults.countText(outcome(count: 500, capped: true)) == "500+ matches, type more to narrow it down")
}
@Test func detailIsPageAndChapter() {
    #expect(SearchResults.detail(match(page: 142, chapter: "The Letter")) == "142 · The Letter")
    #expect(SearchResults.detail(match(page: 142, chapter: nil)) == "142")
}
```
In `ReaderCommandsTests`: `#expect(ReaderCommand(key: "f", modifiers: [.command]) == .find)`. The plain-F fullscreen test and the ⌃⌘F test must still pass.

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/test.sh SearchResultsTests`
Expected: FAIL, because `SearchResults` isn't defined.

- [ ] **Step 3: Implement `SearchResults`, `ReaderCommand.find` and the menu item.** Make `showSearch()` an empty private stub in the controller for now.

- [ ] **Step 4: Run the tests to see them pass**

Run: `scripts/test.sh SearchResultsTests`, then `scripts/test.sh ReaderCommandsTests`
Expected: PASS. `noTwoCommandsShareAShortcut` still passes.

- [ ] **Step 5: Commit**

```bash
git add Readme/Reader/Search.swift Readme/Reader/ReaderCommand.swift Readme/App/ReadmeApp.swift \
  Readme/Reader/ReaderWindowController.swift ReadmeTests/SearchResultsTests.swift ReadmeTests/ReaderCommandsTests.swift
git commit -m "feat: Find command and search result wording"
```

---

### Task 4: The floating search box

**Files:**
- Create: `Readme/Reader/SearchBox.swift`
- Modify: `Readme/Reader/ReaderWindowController.swift` (the view, its layout next to `pageField` around line 1417, its theme next to line 1460, `desk.chrome`, and `showSearch` / `closeSearch` / `pick`)
- Test: `ReadmeTests/SearchWindowTests.swift` (use the setup from `MarkerWindowTests`)

**Interfaces:**
- Consumes: `BookWebView.search(_:limit:)` and `flash(_:)` (Task 2). `SearchResults` and `.find` (Task 3).
- Produces, on `SearchBox: NSView`:
  ```swift
  static let width: CGFloat = 420
  var onQuery: ((String) -> Void)?           // after the typing pause
  var onPick: ((Int) -> Void)?               // row index
  var onClose: (() -> Void)?
  func setTheme(_ theme: Theme)
  func begin(query: String, outcome: SearchOutcome?, selected: Int?)   // fills, takes the keyboard
  func show(_ outcome: SearchOutcome?, for query: String)              // nil outcome: empty list, no count
  ```
  On the controller, for tests: `var isSearchShown: Bool`, `var searchOutcome: SearchOutcome?`, `var searchQuery: String`, `var searchSelection: Int?`, `func search(_ query: String) async` (searches straight away, skipping the pause), `func pickSearchMatch(at index: Int)`, and `func closeSearch()`.

- [ ] **Step 1: Write the failing tests in `SearchWindowTests`**

```swift
@Test func findOpensTheBoxAndSearchListsMatches() async throws {   // search.epub
    reader.perform(.find); #expect(reader.isSearchShown)
    await reader.search("elena"); #expect(reader.searchOutcome?.matches.count == 3)
}
@Test func pickingAMatchMovesTheSavedPlace() async throws {        // long.epub
    reader.perform(.find); await reader.search("harbour")
    let match = try #require(reader.searchOutcome?.matches.dropFirst(40).first)
    reader.pickSearchMatch(at: 40); await reader.settled()
    #expect(!reader.isSearchShown)
    #expect(try #require(reader.location).page <= match.page)
    await reader.placesKept()   // reopening a new controller on the same folder opens at that page
}
@Test func findAgainKeepsTheLastSearch() async throws {
    // search "elena", pick 1, perform(.find): searchQuery == "elena", outcome unchanged, searchSelection == 1
}
@Test func escapeClosesWithoutMoving() async throws {
    // perform(.find), search, closeSearch(): isSearchShown false, location unchanged
}
@Test func searchNeverTouchesTheMarker() async throws {
    // toggleMarker, find+search+pick elsewhere: reader.marker unchanged
}
@Test func oneLetterSearchesNothing() async throws {
    // search("e") → searchOutcome == nil
}
@Test func aStaleReplyIsDropped() async throws {
    // async let a = reader.search("the"); await reader.search("harbour"); await a
    // searchQuery == "harbour" and outcome is harbour's
}
@Test func clickingARowGoesToIt() async throws {
    // SearchBox in a window: begin with an outcome, send a mouseDown to row 2's rect → onPick(2) fires and onClose does not fire first
}
@Test func openingAnotherBookForgetsTheSearch() async throws {
    // search, then open another fixture: searchQuery == "" and searchOutcome == nil
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/test.sh SearchWindowTests`
Expected: FAIL, because `isSearchShown` isn't defined.

- [ ] **Step 3: Build `SearchBox`**

Its backdrop, tint, corner radius and theming copy `GoToPageField`: `ReaderToolbar.chrome` and `ink`. From top to bottom it holds:
- the text field
- a count label (`SearchResults.countText`, ink at 0.55)
- a list with at most 7 visible rows that scrolls beyond that

Each row shows `pre`, `match` and `post` on one truncated line, with `match` in the semibold weight, and `SearchResults.detail` right-aligned and dimmed. A row's height fits the one line.

Typing restarts a 250 ms pause before calling `onQuery`. In `control(_:textView:doCommandBy:)`:
- `moveUp` and `moveDown` move the selection.
- `insertNewline` calls `onPick` with the selected row, or beeps if there isn't one.
- `cancelOperation` calls `onClose`.

The list never takes first responder. Rows are picked on mouse-down inside the box. A click outside the box closes it through `controlTextDidEndEditing`, as in `GoToPageField`. That handler must ignore the end of editing a row click causes. Track that with a flag set on mouse-down.

- [ ] **Step 4: Wire it into the controller**

- `showSearch()` closes the contents and the page field. It shows `contentsScrim` behind the box, and clicking the scrim closes the box. It places the box centred, 52 pt from the top like `pageField`, and calls `begin` with the kept query, outcome and selection.
- `search(_:)` stores the query. If `!isSearchable`, it clears the outcome. Otherwise it awaits `session.book.search(query, limit: SearchResults.limit)`, then drops the reply if `searchQuery` has changed since, or if the reply is nil.
- `pickSearchMatch(at:)` stores the selection, closes the box, and calls `jump { book in let landed = await book.go(toCFI: m.cfi); await book.flash(m.cfi); return landed }`.
- Opening a book clears the query, outcome and selection. Leaving for the library doesn't.
- `jump` already closes the contents and the page field. Add `closeSearch()` there too.

- [ ] **Step 5: Run the tests to see them pass**

Run: `scripts/test.sh SearchWindowTests`, then `scripts/test.sh` (the whole suite)
Expected: all pass.

- [ ] **Step 6: Record it in the main design**

In `docs/superpowers/specs/2026-10-30-mac-book-reader-design.md`, take "search" out of the Non-goals line. Add "Page number (added after v1)" and "Search (added after v1)" sections in the same voice as the Highlights and Reading marker ones, summarising the new spec.

- [ ] **Step 7: Owner try.** Build with `scripts/build_app.sh`. In a real book, press ⌘F, type a character's name, arrow down, and press Return. The match should glow, then fade. Press ⌘F again and the list should still be there. Press Esc. Try it in night theme and in fullscreen.

- [ ] **Step 8: Commit**

```bash
git add Readme/Reader/SearchBox.swift Readme/Reader/ReaderWindowController.swift \
  ReadmeTests/SearchWindowTests.swift docs/superpowers/specs/2026-10-30-mac-book-reader-design.md
git commit -m "feat: floating search box"
```
