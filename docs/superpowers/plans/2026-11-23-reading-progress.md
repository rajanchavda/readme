# Reading Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show how far through each book you are, mark books finished (automatically by turning pages past 95%, or by hand), and add Reading and Finished chips to the shelf.

**Architecture:** `Book` gains `progress` and `finishedAt`. The reader decides, on each kept place, whether turning pages just crossed the finish line, and passes that flag through `ReadMarker` to `LibraryStore.markRead`. The shelf's filter grows from "a collection or All" into `ShelfFilter` (all, reading, finished, a collection). The covers get a progress bar under them, a double tick in the corner when finished, and a macOS tooltip.

**Tech Stack:** Swift, SwiftUI hosted in AppKit, Swift Testing (`@Test`, `#expect`), XcodeGen. Tests run with `scripts/test.sh [Suite | Suite/test()]`.

**Spec:** `docs/superpowers/specs/2026-11-22-reading-progress-design.md` (mockups: the "Reading progress" page of https://claude.ai/artifact/5tXPoe8GgMNEeFQN8ZNdgN).

## Global Constraints

- Finish threshold: `0.95`. Only page turns finish a book, never jumps (contents, Go to Page, End key, links, marker, search, highlights).
- `progress` and `finishedAt` are optional in `library.json`; files from before still load. `formatVersion` stays 1.
- Backfill sets `progress` from saved places and never finishes a book.
- Marking by hand never moves the reading place. Mark as Not Finished clears `finishedAt` and nothing else.
- Covers: no bar for a book never opened, no bar for a finished book. Bar: 3 pt, 7 pt below the cover, cover width, track `ShelfStyle.text` at 0.10, fill `PinRibbon.color` at 0.85.
- Finished mark: a white double tick in the cover's bottom-right corner, on a dark shade about 34 × 30 pt at a 112 pt cover (scaled with width), black 0.5 at the corner, 0.28 at 40%, clear at 72%. No circle.
- Tooltip: the standard `.help`, two lines: "Title — Author", then "64% · Chapter 12", "Finished 18 Nov", or nothing for a book never opened. None on the ledge's book.
- Menu order: Remove from X (collection active) + divider, Add to Collection, Export…, Pin to Front, Mark as Finished / Mark as Not Finished, divider, Remove.
- Chip row: All, Reading, Finished, the collections, +. A built-in chip with no books is hidden. Built-ins have no context menu and aren't in Add to Collection. The row shows once a collection exists or any book has been opened.
- Never use the `gh` CLI. Temporary files go in `scratchpad/`.

## Review Focus

1. A page turn crosses 95% and, within ReadMarker's 2 s window, a jump lands elsewhere: the book should still finish (the flag is OR-ed across coalesced reads). Test in Task 2.
2. The Reading chip is active and its last book gets finished, or the Finished chip is active and its last book is unmarked: the shelf should go back to All, not show nothing. Test in Task 4.
3. Backfill on a library where some books already have `progress`: leaves those alone, fills only the missing, finishes nothing. Test in Task 1.
4. Combine-importing a book already finished here: keeps its own date; Keep Mine changes nothing. Test in Task 3.
5. Reopening a finished book and reading from the start: `markRead` without the finishing flag never clears `finishedAt`. Test in Task 1.

---

### Task 1: Progress and finished dates in the store

**Files:**
- Modify: `Readme/Library/Book.swift`
- Modify: `Readme/Library/LibraryStore.swift` (`markRead`, `applyImported`, new `setFinished`, `restoreFinished`, backfill in `init`)
- Test: `ReadmeTests/ReadingProgressStoreTests.swift` (new)

**Interfaces:**
- Produces:
  - `Book.progress: Double?` (0…1), `Book.finishedAt: Date?`, both `= nil`, decoded with `decodeIfPresent`.
  - `Book.isFinished: Bool { finishedAt != nil }`, `Book.isStarted: Bool { progress != nil }`.
  - `nonisolated static func Book.progress(of location: ReaderLocation) -> Double` returns `1` when `isAtEnd`, else `fraction` clamped to 0…1.
  - `LibraryStore.markRead(id: String, location: ReaderLocation, finishing: Bool = false)`
  - `LibraryStore.setFinished(ids: [String], finished: Bool)`
  - `LibraryStore.restoreFinished(id: String, at: Date)`: sets `finishedAt` only when it's nil (for imports).
  - `applyImported(…, location:)` also sets `progress` from `location`.

- [ ] **Step 1: Write the failing tests** in `ReadingProgressStoreTests` (a `@MainActor @Suite`, with a private `book(_:)` helper and a `ReaderLocation` helper `place(_ fraction: Double, end: Bool = false)`, as in `CollectionStoreTests`; use `LibraryStore(directory:now:)` with a fixed clock):
  - `markReadCopiesProgress`: `markRead(id: "a", location: place(0.42))` → `progress == 0.42`; a place with `isAtEnd` → `progress == 1`.
  - `finishingSetsTheDateOnce`: `markRead(…, finishing: true)` at clock t1 → `finishedAt == t1`; again with `finishing: true` at t2 → still t1.
  - `readingAgainNeverUnfinishes`: a finished book, then `markRead(id:location: place(0.01))` (no flag) → `finishedAt` unchanged, `progress == 0.01`.
  - `setFinishedOnAMixedSelection`: "a" finished at t1, "b" not; `setFinished(ids: ["a","b"], finished: true)` at t2 → a keeps t1, b gets t2; `setFinished(… false)` → both nil, `progress` untouched.
  - `oldLibraryFileLoads`: the JSON from `CollectionStoreTests.oldLibraryFileLoads` → `progress == nil`, `finishedAt == nil`.
  - `savedAndReloaded`: progress and finishedAt survive `await store.saved()` and a new store.
  - `backfillFillsOnlyMissingAndFinishesNothing`: write `library.json` with "a" (no progress) and "b" (`progress = 0.3`); save a place of 0.98 for both into a `PositionStore(directory: folder/Positions)` before creating the store → a gets 0.98, b keeps 0.3, neither has `finishedAt`.
  - `applyImportedSetsProgress`: `applyImported(id:addedAt:nil, lastReadAt:nil, location: place(0.6))` → `progress == 0.6`.
  - `restoreFinishedNeverMovesADate`: nil → set; already set → unchanged.

- [ ] **Step 2: Run** `scripts/test.sh ReadingProgressStoreTests`. Expected: build fails (no `progress`).

- [ ] **Step 3: Implement.** Add the fields and decoding lines to `Book`. In `markRead`, set `progress = Book.progress(of: location)` and, if `finishing && finishedAt == nil`, `finishedAt = now()`. `setFinished` follows `setPinned`'s shape (one timestamp, save only if changed). The backfill runs at the end of `init`: for each book with `progress == nil`, `positions.locationNow(bookID:)` → `Book.progress(of:)`; call `save()` if anything changed.

- [ ] **Step 4: Run** `scripts/test.sh ReadingProgressStoreTests CollectionStoreTests LibraryStoreTests`. Expected: PASS.

- [ ] **Step 5: Commit** `feat: keep reading progress and finished dates on books`.

### Task 2: Finishing by turning pages

**Files:**
- Create: `Readme/Library/FinishRule.swift`
- Modify: `Readme/App/AppCoordinator.swift` (`ReadMarker`, the `onRead` wiring)
- Modify: `Readme/Reader/ReaderWindowController.swift` (`onRead` signature, `relocated`, `keep`, `turn`, the swipe handler, `jump`, `onLink`, session start)
- Test: `ReadmeTests/FinishRuleTests.swift` (new); add to `ReadingWiringTests` in `ReadmeTests/StaleBookTests.swift`; `ReadmeTests/FinishWindowTests.swift` (new)

**Interfaces:**
- Consumes: `LibraryStore.markRead(id:location:finishing:)` from Task 1.
- Produces:
  - `enum FinishRule { static let threshold = 0.95; nonisolated static func finishes(from previous: ReaderLocation?, to location: ReaderLocation, byTurning: Bool) -> Bool }`
  - `ReadMarker.init(interval:mark: @escaping (String, ReaderLocation, Bool) -> Void)`, `ReadMarker.read(id:location:finishing: Bool = false)`
  - `ReaderWindowController.onRead: ((_ bookID: String, ReaderLocation, _ finishing: Bool) -> Void)?`

The rule: true only when `byTurning`, `previous` is non-nil, and either the place crosses the threshold (`previous.fraction < 0.95 && !previous.isAtEnd` and now `fraction >= 0.95 || isAtEnd`) or it reaches the last spread (`!previous.isAtEnd && location.isAtEnd`). Reaching the last spread by turning counts even from above 95%: it's a deliberate end, and it's what the spec means by "reaches `isAtEnd` by page turns".

- [ ] **Step 1: Write the failing tests.**
  - `FinishRuleTests`: crossing 0.94 → 0.96 by turning finishes; the same by a jump doesn't; 0.96 → 0.97 doesn't (after Mark as Not Finished); 0.97 → `isAtEnd` by turning does; `previous == nil` doesn't; 0.5 → 0.99 by a jump doesn't.
  - In `ReadingWiringTests`: `finishingSurvivesCoalescing`. With `interval: .seconds(3600)`: read "a" at 0.5 (marked at once), read "a" at 0.96 `finishing: true` (pending), read "a" at 0.3 `finishing: false` (pending), `flush()` → the last mark is 0.3 with `finishing == true`. Update the existing tests there to the three-argument closure.
  - `FinishWindowTests` (`@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))`, using the same `reader(in:)` and `positionsFolder()` set-up as `MarkerWindowTests` and `long.epub`): record `onRead` calls.
    - `turningPastTheLineFinishes`: `goToPage(typed:)` to `Int(Double(pageCount) * 0.93)`, `settled()`, clear the record, then `turn(.forward)` until `location.fraction >= 0.95 || isAtEnd` (at most 40 times) with `placesKept()` → some recorded call has `finishing == true`.
    - `jumpingToTheEndDoesNot`: `perform(.goToEnd)`, `settled()` → every recorded call has `finishing == false`.

- [ ] **Step 2: Run** `scripts/test.sh FinishRuleTests ReadingWiringTests FinishWindowTests`. Expected: build fails.

- [ ] **Step 3: Implement.**
  - `FinishRule` as above.
  - `ReadMarker`: `pending` gains `finishing: Bool`. On a read for the same book while one is pending, `finishing = pending.finishing || finishing`.
  - Reader:
    - Add `private var movedByTurning = false` and `private var lastPlace: ReaderLocation?`. Reset both when a session starts.
    - Set `movedByTurning = true` in `turn(_:isRepeat:)` and in the swipe handler's `.start` case. Set it to `false` in `jump(_:)` and in `book.onLink`.
    - In `relocated`, compute `FinishRule.finishes(from: lastPlace, to: location, byTurning: movedByTurning)` before setting `lastPlace = location`, and pass it to `keep`. This runs while laying out too, so the opening place counts as "previous", but `keep` isn't called then.
    - `keep` calls `onRead?(bookID, location, finishing)`.
  - `AppCoordinator`: `ReadMarker { id, location, finishing in library?.markRead(id: id, location: location, finishing: finishing) }`, and `reader.onRead = { … self?.marker.read(id:location:finishing:) }`.

- [ ] **Step 4: Run** `scripts/test.sh FinishRuleTests ReadingWiringTests FinishWindowTests MarkerWindowTests JumpTests`. Expected: PASS.

- [ ] **Step 5: Commit** `feat: finish a book by turning pages past 95%`.

### Task 3: Finished dates in library bundles

**Files:**
- Modify: `Readme/Library/LibraryBundle.swift` (`BundledBook.finishedAt: Date? = nil`)
- Modify: `Readme/Library/LibraryExporter.swift`, `Readme/Library/LibraryImporter.swift` (`add`, `combine`)
- Modify: `docs/readmelibrary-format.md` (a `finishedAt` row after `collections`: "date, optional | When it was finished. Absent when it isn't, and in bundles from before reading progress")
- Test: `ReadmeTests/LibraryBundleTests.swift`, `ReadmeTests/LibraryImporterTests.swift`

**Interfaces:**
- Consumes: `restoreFinished(id:at:)`, and `applyImported` setting `progress` (Task 1).

- [ ] **Step 1: Write the failing tests**, following the existing collections tests in both files:
  - Bundle round-trip keeps `finishedAt`; a `book.json` without the key reads as nil.
  - Importer: a new book keeps the bundle's `finishedAt` and gets `progress` from `position.json`.
  - Combine onto a book here that isn't finished → takes the bundle's date.
  - Combine onto a book finished here at t1, from a bundle with t2 → keeps t1.
  - Keep Mine onto an unfinished book → stays unfinished.

- [ ] **Step 2: Run** `scripts/test.sh LibraryBundleTests LibraryImporterTests`. Expected: build fails.

- [ ] **Step 3: Implement.**
  - The exporter passes `finishedAt: book.finishedAt`.
  - `add` and `combine` each call `if let date = contents.info.finishedAt { store.restoreFinished(id: id, at: date) }`. In `combine`, place it next to `joinCollections`.
  - Keep Mine doesn't reach `combine`, so it changes nothing, matching collections.

- [ ] **Step 4: Run** `scripts/test.sh LibraryBundleTests LibraryImporterTests LibraryExporterTests`. Expected: PASS.

- [ ] **Step 5: Commit** `feat: carry finished dates in library bundles`.

### Task 4: Reading and Finished chips

**Files:**
- Create: `Readme/Library/ShelfFilter.swift`
- Modify: `Readme/Library/ShelfCollections.swift`, `Readme/Library/CollectionChips.swift`, `Readme/Library/LibraryView.swift`, `Readme/Library/ShelfRow.swift`
- Test: `ReadmeTests/ShelfCollectionsTests.swift`

**Interfaces:**
- Consumes: `Book.isStarted`, `Book.isFinished` (Task 1).
- Produces:
  - `enum ShelfFilter: Hashable, Sendable { case all, reading, finished, collection(UUID) }`
  - `ShelfCollections.filter: ShelfFilter` (`@Published`, starts `.all`). `activeID` stays as a computed get/set over it (`.collection(id)` ↔ id, nil ↔ `.all`), so the collections code and tests keep working.
  - `ShelfCollections.filter(in library: LibraryStore) -> ShelfFilter`: the one showing, or `.all` when its collection is gone or its built-in chip is hidden.
  - `nonisolated static func ShelfCollections.shown(_ books: [Book], filter: ShelfFilter) -> [Book]`
    - `.reading`: books where `isStarted && !isFinished`.
    - `.finished`: books where `isFinished`, sorted by `finishedAt` newest first.
    - `.collection`: as today.
    - The old `shown(_:in:)` becomes a one-line wrapper.
  - `nonisolated static func ShelfCollections.builtInChips(_ books: [Book]) -> [ShelfFilter]`: `.reading` when any book is reading, then `.finished` when any book is finished.
  - `static func ShelfCollections.showsChipRow(_ library: LibraryStore) -> Bool`: true when any collection exists or any book `isStarted`.
  - `shelfOrder(_:filter:)` replaces `shelfOrder(_:collection:)`.

- [ ] **Step 1: Write the failing tests** in `ShelfCollectionsTests`:
  - `readingAndFinishedContents`: books never opened, reading at 0.4, finished (with progress 1) → `.reading` gives the 0.4 one; `.finished` gives the finished one.
  - `finishedIsNewestFirst`: three finished at t1, t3, t2 → order t3, t2, t1.
  - `hiddenWhenEmpty`: `builtInChips` with nothing started → `[]`; with one reading → `[.reading]`; with both → `[.reading, .finished]`.
  - `aBuiltInChipThatEmptiesGoesBackToAll`: `filter = .reading` on a library whose only reading book is then finished through `setFinished` → `filter(in:) == .all`.
  - `chipRowShowsAfterTheFirstBookIsOpened`: no collections, no progress → false; `markRead` one book → true.
  - `shelfOrderUnderFinished`: `shelfOrder(library, filter: .finished)` is the finished books, current one first if finished, then newest finished first.
  - `escapeGoesBackToAllFromABuiltIn`: as the existing escape test, with `filter = .finished`.

- [ ] **Step 2: Run** `scripts/test.sh ShelfCollectionsTests`. Expected: build fails.

- [ ] **Step 3: Implement.**
  - `ShelfFilter` and the `ShelfCollections` members above. `active(in:)` stays for the collection-only callers (Remove from X, the empty line, the delete alert).
  - `LibraryView`/`Shelves`:
    - Replace `collection: UUID?` with `filter: ShelfFilter` from `collections.filter(in: library)`, in `Shelves`, `found`, `shows` and the animation value.
    - Replace `library.collections.isEmpty` with `!ShelfCollections.showsChipRow(library)` for both the chip overlay and the 20 pt top padding.
  - Under `.finished`, `Shelves` lays out `shown(library.others, filter:)` as returned, so the date order holds.
  - `ShelfBook.order` uses `shelfOrder(_:filter:)`.
  - `CollectionChips`:
    - `Chip` is keyed by `ShelfFilter` (All, then `builtInChips(library.books)` named "Reading" and "Finished", then the collections).
    - The active index is found against `collections.filter(in: library)`, and tapping a chip sets `collections.filter`.
    - Built-in chips get no context menu, and their accessibility label is the name alone.

- [ ] **Step 4: Run** `scripts/test.sh ShelfCollectionsTests ShelfSelectionTests ShelfSearchTests ShelfLayoutTests`. Expected: PASS.

- [ ] **Step 5: Commit** `feat: Reading and Finished chips`.

### Task 5: Bars, ticks, tooltip and menu on the shelf

**Files:**
- Create: `Readme/Library/ReadingMarks.swift` (`ProgressBar`, `FinishedTicks`, `DoubleTick` shape, and the text helpers below)
- Modify: `Readme/Library/ShelfRow.swift` (`ShelfBook`), `Readme/Library/CurrentBookShelf.swift`, `Readme/Library/ShelfSelection.swift`
- Modify: `docs/Readme for Windows checklist.md` (a Reading progress item and a current-state line), and the spec's `Status:` line to "built"
- Test: `ReadmeTests/ReadingMarksTests.swift` (new), `ReadmeTests/ShelfSelectionTests.swift`

**Interfaces:**
- Consumes: `Book.progress`, `finishedAt`, `isStarted`, `isFinished`; `LibraryStore.setFinished(ids:finished:)`.
- Produces (all `nonisolated static` on `enum ReadingMarks`):
  - `percent(_ progress: Double) -> Int`: `Int((progress * 100).rounded(.down))`, clamped to 0…100.
  - `tooltip(for book: Book, now: Date = Date(), locale: Locale = .current) -> String`
  - `accessibilityLabel(for book: Book) -> String`
  - `ledgeLine(for book: Book) -> String?`, replacing `CurrentBookShelf.progressLine(for:)`, whose tests move here.
- `ShelfSelection.finishMenuTitle(count: Int, allFinished: Bool) -> String`

- [ ] **Step 1: Write the failing tests.**
  - `ReadingMarksTests`, with `locale: Locale(identifier: "en_GB")` and dates at 12:00 UTC:
    - `percent(0.999) == 99`, `percent(1) == 100`.
    - Tooltip:
      - a started book → `"The Psychology of Money — Morgan Housel\n64% · Chapter 12"`
      - started, with no chapter → `"…\n64%"`
      - finished 18 Nov 2026, now 23 Nov 2026 → `"…\nFinished 18 Nov"`
      - finished in 2025 → `"…\nFinished 18 Nov 2025"`
      - never opened → `"The Psychology of Money — Morgan Housel"`
      - no author → the title alone on the first line.
    - Accessibility label: `"Title, Author, 42% read"`, `"Title, Author, pinned, finished"`, never opened → `"Title, Author"`.
    - Ledge line:
      - with progress → `"42% · Chapter 7 · 12 min left"`
      - finished → `"Chapter 7 · 12 min left"`, without the percentage, since the tick already says it
      - never opened → today's line.
  - `ShelfSelectionTests`: `finishMenuTitle` gives "Mark as Finished", "Mark 3 Books as Finished", "Mark as Not Finished" and "Mark 3 Books as Not Finished".

- [ ] **Step 2: Run** `scripts/test.sh ReadingMarksTests ShelfSelectionTests`. Expected: build fails.

- [ ] **Step 3: Implement.**
  - `ProgressBar(progress:width:)`: the 3 pt capsule track with its fill.
  - `DoubleTick: Shape`: two strokes in an 18 × 14 box at a 112 pt cover. The paths are `M1.5 7.4 l3 3 l6 -6.6` and `M8.6 10.1 l0.3 0.3 l6 -6.6`, as in the mockup, scaled by `width / 112`.
  - `FinishedTicks(width:)`: an `EllipticalGradient` shade anchored at `.bottomTrailing` with the stops in Global Constraints. On it, the tick stroked white at 1.7 pt, round caps and joins, shadow black 0.5 radius 1 y 1, inset 5 pt from the corner.
  - `ShelfBook`:
    - The label becomes a `VStack(spacing: 7)`: the cover (ribbon and selection ring as now), then a `ProgressBar` when `isStarted && !isFinished`, else a clear 3 pt spacer.
    - `.overlay(alignment: .bottomTrailing) { FinishedTicks }` on the cover, so it lifts with it. Use `.transition(.opacity)`, animated unless Reduce Motion is on, and `.accessibilityHidden(true)` on both the bar and the ticks.
    - `.help(ReadingMarks.tooltip(for: book))` unless the new `showsTooltip` parameter is false; `CurrentBookShelf` passes false.
    - Accessibility label from `ReadingMarks.accessibilityLabel`.
    - An accessibility action named "Mark as Finished" or "Mark as Not Finished".
    - A `finishButton` after `pinButton`, built like it, on `selection.targets(rightClicked:order:)`.
  - `CurrentBookShelf` uses `ReadingMarks.ledgeLine`.
  - `ShelfLayout.shelfHeight`/`ledgeHeight` grow only if the 10 pt bar slot makes covers clip. Check by running the app.

- [ ] **Step 4: Run** `scripts/test.sh ReadingMarksTests ShelfSelectionTests`, then the whole suite with `scripts/test.sh`. Expected: PASS, apart from the known `PageShortcutTests/aPageNumberSurvivesAFontSizeChange()` and flaky `SpreadCacheTests/landingMatchesFromAWindowOnScreen()`.

- [ ] **Step 5: Look at it.**
  - Back up `~/Library/Containers/com.rajanchavda.Readme` to `scratchpad/library-backup-<date>`, then run `scripts/build_app.sh` and open `build/Readme.app`.
  - Check the bars, the ticks on pale and dark covers, the tooltip, the menu and the chips.

- [ ] **Step 6: Commit** `feat: progress bars, finished ticks and book tooltips on the shelf`.
