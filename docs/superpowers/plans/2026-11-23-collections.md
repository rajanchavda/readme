# Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people group books into their own collections and filter the shelf by them with a row of chips on the search's line.

**Architecture:** `LibraryStore` keeps the collections in a new `collections.json` and each book's memberships in `Book.collectionIDs`. A new `ShelfCollections` object, owned by `AppCoordinator` like `ShelfSearch` and `ShelfSelection`, holds which chip is active and which sheet or dialog is showing. `LibraryView` filters through it and draws the chip row. A pure `ChipRowLayout` decides which chips fit and which go into the More menu. Bundles carry collection names, not IDs.

**Tech Stack:** Swift, SwiftUI hosted in AppKit, Swift Testing (`@Test`, `#expect`), XcodeGen. Run tests with `scripts/test.sh [Suite | Suite/test()]`; it runs `xcodegen generate` itself, so new files need no project edits.

**Spec:** `docs/superpowers/specs/2026-11-22-collections-design.md`

## Global Constraints

- The word is **Collection** in the UI. The type is `BookCollection`, since Swift's `Collection` is taken.
- Names: leading and trailing spaces trimmed, empty refused, up to 40 characters. Unique ignoring case and accents, using the same folding as `ShelfSearch`.
- Suggestions, in this order, leaving out any that already exist: Fiction, Self-Help, Business, Investing, Biography, History, Philosophy, Spirituality, Science.
- Chips: **All**, then collections alphabetically (`localizedStandardCompare`), then **+**. The row shows once at least one collection exists. One chip is active at a time, and the app always opens on **All**.
- Chip look: a capsule 30pt high, like the search field, in `ShelfStyle.body(16)`. The active chip is filled `ShelfStyle.text` with `ShelfStyle.bottom` text. The others have a `ShelfStyle.text.opacity(0.14)` outline and `ShelfStyle.soft` text. No counts.
- Chips that don't fit go into an "N more ▾" menu. **+** always stays visible. The row never scrolls or wraps. The active chip is always on the row.
- Book menu, top to bottom: **Remove from <Name>** (only while a collection is active) and a divider, then **Add to Collection ▸**, **Export…**, **Pin to Front**, a divider, and **Remove**.
- Copy, exactly:
  - "No books in <Name> yet. Right-click a book and choose Add to Collection."
  - "Delete <Name>?" / "The 12 books in it stay in your library." (and "The 1 book in it stays in your library.")
  - "Adds the 2 selected books." / "Adds this book."
  - "New Collection", "New Collection…", "Rename…", "Delete Collection", "Add to Collection", "Remove from <Name>".
- `collections.json` is written whole, atomically and off the main thread, like `library.json`.
- Bundle `formatVersion` stays 1. `book.json` gains `collections: [String]` (names), left out when empty.
- Animations respect Reduce Motion.
- No `gh` CLI; plain `git` only. Work on branch `feat/collections`.

## Decisions the spec leaves open

- **A corrupt `collections.json`.** Stale IDs are pruned at launch only when `collections.json` is missing or reads cleanly. If the file is there but can't be read, the books keep their IDs, which point at nothing, so one bad file can't wipe every membership.
- **Bundle import with "Keep mine".** An existing book gains the bundle's collections only with **Combine**. **Keep mine** promises to leave existing books exactly as they are, and it still does.
- **Renaming to a name another collection has.** The Rename sheet's Save button is disabled, with a quiet line: "There's already a collection called <Name>." Renaming to the same name with different case is allowed.
- **Esc order.** Esc clears the search first, then the selection, then goes back to All.
- **Dropping books already in the library while a collection is active.** They join the collection too, since the drop names them.
- **Rename and Delete for chips in the More menu.** These aren't offered from the menu. Picking a chip moves it onto the row, where it can be right-clicked.

## Review Focus

1. **Deleting the collection that's showing.** The shelf goes back to All, and no chip stays filled for a collection that's gone. Test in Task 2.
2. **A name only of spaces, or over 40 characters.** Spaces alone are refused; a long name is cut at 40, not refused. Test in Task 1.
3. **"self-help" typed in New Collection when "Self-Help" exists.** No duplicate is made. The books join "Self-Help". Test in Task 1.
4. **The window narrowed until even one collection chip doesn't fit next to All and the More chip.** All and More stay, everything else goes into the menu, and nothing overlaps the search. Test in Task 3.
5. **A bundle naming "INVESTING" imported into a library with "Investing".** The book joins "Investing", and no second collection appears. Test in Task 5.

---

### Task 0: Branch

- [ ] **Step 1:** `git switch docs/collections-and-progress-specs && git switch -c feat/collections`

### Task 1: Collections in the library

**Files:**
- Create: `Readme/Library/BookCollection.swift`
- Modify: `Readme/Library/Book.swift`, `Readme/Library/LibraryStore.swift`, `Readme/Library/ShelfSearch.swift` (make `fold` internal)
- Test: `ReadmeTests/CollectionStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct BookCollection: Codable, Identifiable, Equatable, Sendable { var id: UUID; var name: String; var createdAt: Date }`
  - `BookCollection.maxNameLength = 40`
  - `static func BookCollection.cleanName(_ raw: String) -> String?`: trimmed, cut to 40, nil if empty.
  - `static let BookCollection.suggestedNames: [String]` (the spec's nine, in order)
  - `static func BookCollection.suggestions(excluding existing: [BookCollection]) -> [String]`
  - `Book.collectionIDs: [UUID] = []`. Decoding treats a missing key as `[]`.
  - `ShelfSearch.fold(_:) -> String`, now `nonisolated static`, internal rather than private.
  - On `LibraryStore`:
    - `@Published private(set) var collections: [BookCollection]`, always sorted by name.
    - `func collection(id: UUID) -> BookCollection?`
    - `func collection(named name: String) -> BookCollection?`, matched by folded name.
    - `@discardableResult func createCollection(name: String) -> BookCollection?` returns the existing collection for a folded-equal name, and nil for a name `cleanName` refuses.
    - `@discardableResult func renameCollection(id: UUID, to name: String) -> Bool` is false for a refused name, or one another collection has.
    - `func deleteCollection(id: UUID)` also strips the ID from every book.
    - `func setCollection(_ id: UUID, member: Bool, ids: [String])`
    - `func joinCollections(named names: [String], id bookID: String)` creates any that are missing, and never removes one.

- [ ] **Step 1: Write the failing tests** in `CollectionStoreTests` (`@MainActor @Suite`, using `libraryFolder()` and a local `book(_:added:)` helper like `LibraryStoreTests`):
  - `createTrimsAndCaps`: `createCollection(name: "  Self-Help ")?.name == "Self-Help"`. `createCollection(name: "   ") == nil`. A 50-character name is stored as its first 40.
  - `duplicateNameReturnsTheExisting`: after creating "Self-Help", `createCollection(name: "self-help")?.id` is the first one's ID, and so is `"Sélf-help"`. `collections.count == 1`.
  - `collectionsAreAlphabetical`: create "Investing", "business", "Fiction". The names come back as `["business", "Fiction", "Investing"]`.
  - `renameRefusesAnotherCollectionsName`: with "Fiction" and "History", renaming History to "fiction" returns false and nothing changes. Renaming Fiction to "FICTION" returns true.
  - `deleteStripsMemberships`: put "a" and "b" in X, delete X, and both books have `collectionIDs == []`.
  - `membershipOnASelection`: `setCollection(x, member: true, ids: ["a","b"])` adds both, with no duplicates when it runs twice. `member: false` removes both. Unknown book IDs are passed over.
  - `savedAndReloaded`: create, add a member, `await store.saved()`. A new `LibraryStore` on the same folder has the same collections and memberships.
  - `oldLibraryFileLoads`: write a `library.json` with no `collectionIDs` key (encode a book, strip the key in a dictionary, write it back). It loads with `collectionIDs == []`.
  - `unknownIDsAreDropped`: a reloaded book pointing at a UUID that's not in `collections.json` has an empty `collectionIDs`.
  - `corruptCollectionsFileKeepsIDs`: write garbage to `collections.json` with a book that has a membership. After reload, `collections` is empty but the book still has its ID.
  - `joinCollectionsByName`: with "Investing", `joinCollections(named: ["INVESTING", "Travel"], id: "a")` gives "a" two memberships and makes "Travel". "Investing" is the same ID as before.
  - `suggestionsLeaveOutExisting`: with "fiction" and "Science", `suggestions(excluding:)` returns `["Self-Help", "Business", "Investing", "Biography", "History", "Philosophy", "Spirituality"]`.

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test.sh CollectionStoreTests`
Expected: build failure, since `BookCollection` isn't defined.

- [ ] **Step 3: Implement**
  - `Book` needs a hand-written `init(from:)` in an extension in `Book.swift`, so the memberwise init stays. Synthesized decoding would throw on a missing non-optional key. Decode `collectionIDs` with `decodeIfPresent(...) ?? []` and every other field as today.
  - In `LibraryStore`, load `collections.json` in `init` after `library.json`, then prune unknown IDs only as "Decisions" says.
  - Save collections through a second writer with the same "only the newest is written" loop as `save()`. `saved()` awaits both writers. Generalising `LibraryFile` to write any `Encodable` value to a named file is fine.

- [ ] **Step 4: Run them to make sure they pass**

Run: `scripts/test.sh CollectionStoreTests`, then `scripts/test.sh LibraryStoreTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Readme/Library/BookCollection.swift Readme/Library/Book.swift Readme/Library/LibraryStore.swift Readme/Library/ShelfSearch.swift ReadmeTests/CollectionStoreTests.swift
git commit -m "feat: keep collections in the library"
```

### Task 2: The active collection and the filtered shelf

**Files:**
- Create: `Readme/Library/ShelfCollections.swift`
- Modify: `Readme/Library/LibraryView.swift` (`Shelves`, `Shelves.found`, the empty line, a new `collections` init parameter), `Readme/App/AppCoordinator.swift`
- Test: `ReadmeTests/ShelfCollectionsTests.swift`

**Interfaces:**
- Consumes: Task 1's `LibraryStore` collection API, and `Book.collectionIDs`.
- Produces:
  - `@MainActor final class ShelfCollections: ObservableObject`
    - `@Published var activeID: UUID?` (nil is All)
    - `@Published var sheet: CollectionSheet?`
    - `@Published var confirmingDelete: UUID?`
    - `func active(in library: LibraryStore) -> BookCollection?` is nil when `activeID` names a collection that's gone.
    - `func showAll()`
    - `func delete(_ id: UUID, from library: LibraryStore)` returns to All when `id` is active.
    - `func addImported(_ results: [Result<Book, ImportError>], to library: LibraryStore)` adds the successes to the active collection, if there is one.
    - `nonisolated static func shown(_ books: [Book], in collection: UUID?) -> [Book]` keeps order.
    - `static func escape(search: ShelfSearch, selection: ShelfSelection, collections: ShelfCollections)`
    - `nonisolated static func emptyLine(name: String) -> String`
    - `nonisolated static func deleteText(name: String, count: Int) -> (title: String, message: String)`
  - `enum CollectionSheet: Identifiable, Equatable { case create(bookIDs: [String]), rename(UUID) }`

- [ ] **Step 1: Write the failing tests** in `ShelfCollectionsTests`:
  - `shownKeepsOrderAndFilters`: given books a(X), b(), c(X,Y), `shown(_, in: X)` is `[a, c]`, and `shown(_, in: nil)` is all three.
  - `deletingTheActiveGoesBackToAll`: with X active, `delete(X)` leaves `activeID == nil`. Deleting another collection leaves the active one alone.
  - `activeThatIsGoneIsAll`: X active, then `library.deleteCollection(id: X)` directly. `active(in:)` is nil.
  - `importedJoinTheActive`: X active, and `addImported([.success(a), .failure(.unreadable)])` puts a in X. With All active, nothing changes.
  - `escapeOrder`: search open → closes the search only. Then with a selection → clears it only. Then → `activeID == nil`.
  - `copy`: `emptyLine(name: "Self-Help") == "No books in Self-Help yet. Right-click a book and choose Add to Collection."`. `deleteText(name: "Self-Help", count: 12) == ("Delete Self-Help?", "The 12 books in it stay in your library.")`, and for count 1: `"The 1 book in it stays in your library."`.

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test.sh ShelfCollectionsTests`
Expected: build failure.

- [ ] **Step 3: Implement `ShelfCollections`, then wire it in**
  - `LibraryView` takes `collections: ShelfCollections = ShelfCollections()` in every init, and passes it down with `.environmentObject(collections)`.
  - `Shelves` filters `library.others` with `shown` before the search. It shows the ledge only when the current book is in the active collection and matches the search. `Shelves.found` applies the same two filters.
  - When a collection is active and has no books at all, put `emptyLine` where the "No books match" line goes, in the same style. The "No books match" line still wins while a search is active.
  - Add the active ID to the `.animation(value:)` key so the shelf settles when the chip changes.
  - In `AppCoordinator`:
    - Own `let collections = ShelfCollections()`.
    - Create it before `drops`, and wrap the drops closure so that after `importer.importAll($0)` it calls `collections.addImported(results, to: library)`.
    - Pass it to `LibraryView`.
    - Replace the `onLibraryEscape` body with `ShelfCollections.escape(...)`.

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh ShelfCollectionsTests`, then `scripts/test.sh ShelfSearchTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Readme/Library/ShelfCollections.swift Readme/Library/LibraryView.swift Readme/App/AppCoordinator.swift ReadmeTests/ShelfCollectionsTests.swift
git commit -m "feat: filter the shelf by the active collection"
```

### Task 3: The chip row

**Files:**
- Create: `Readme/Library/ChipRowLayout.swift`, `Readme/Library/CollectionChips.swift`
- Modify: `Readme/Library/LibraryView.swift` (overlay and top inset)
- Test: `ReadmeTests/ChipRowLayoutTests.swift`

**Interfaces:**
- Consumes: `ShelfCollections` (`activeID`, `confirmingDelete`, `sheet`, `delete`, `deleteText`), `LibraryStore.collections`.
- Produces:
  - `struct ChipFit: Equatable { var visible: [Int]; var overflow: [Int] }`. Indices are into the chips as given, with All at 0.
  - `enum ChipRowLayout`
    - `static let gap: CGFloat = 8`
    - `static let leading: CGFloat = 88`
    - `static let searchGap: CGFloat = 16`
    - `static func fit(widths: [CGFloat], active: Int, available: CGFloat, moreWidth: CGFloat, addWidth: CGFloat) -> ChipFit`

  The rules for `fit`, which the signature doesn't decide:

```
if sum(widths) + addWidth + gap * widths.count <= available → all visible, no overflow
else:
  budget = available - addWidth - moreWidth - 2 * gap
  take chips from index 0 while running width (each + gap) <= budget; index 0 (All) is always taken
  if `active` isn't taken and more than one chip is: replace the last taken chip with `active`
  overflow = every index not taken, in the original order
```

- [ ] **Step 1: Write the failing tests** in `ChipRowLayoutTests`:
  All of these use moreWidth 80 and addWidth 30.
  - `allFit`: widths `[50, 80, 70]`, available 400, gives visible `[0,1,2]` and overflow `[]`.
  - `someGoToMore`: widths `[50, 90, 90, 90, 90]`, available 460, active 0. Visible is `[0,1,2]` and overflow `[3,4]`.
  - `activeIsSwappedIn`: the same, with active 4. Visible `[0,1,4]`, overflow `[2,3]`.
  - `tooNarrowKeepsAll`: widths `[50, 90]`, available 120, gives visible `[0]` and overflow `[1]`.
  - `lessRoomWithSearchOpen`: the same widths at 848 and at 636 (the closed and open room in a 1000pt window). The visible count at 636 is less than or equal to the count at 848, and the active chip is visible in both.

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test.sh ChipRowLayoutTests`
Expected: build failure.

- [ ] **Step 3: Implement `ChipRowLayout.fit`, then `CollectionChips`**
  - `CollectionChips(library:collections:searchOpen:)` lives in an `.overlay(alignment: .topLeading)` on `LibraryView`, at `.padding(.top, 12).padding(.leading, ChipRowLayout.leading)`.
  - It shows only when `!library.collections.isEmpty`.
  - Available width = the window width − `leading` − (search width: 28 closed, 240 open) − 20 − `searchGap`.
  - Measure each chip as the `NSAttributedString` width of its name in EB Garamond 16, + 28 padding + 2 border. Measure the More chip with the label "99 more".
  - Chip look and copy are as in Global Constraints. The active chip has `.accessibilityAddTraits(.isSelected)` and `.accessibilityRoleDescription("collection")`.
  - The More chip is a `Menu` with `.menuIndicator(.hidden)`, a chip-styled label "\(n) more" and a `chevron.down`. Its items set `activeID`.
  - **+** sets `collections.sheet = .create(bookIDs: [])`, with `accessibilityLabel("New Collection")`.
  - Each collection chip has a `.contextMenu` with **Rename…** (`sheet = .rename(id)`) and **Delete Collection**. Delete removes an empty collection at once. Otherwise it sets `confirmingDelete`, which shows an `.alert` using `deleteText`, with Cancel and a destructive Delete.
  - When the row shows, add 20pt of top padding to `Shelves` so the ledge cover clears the chips.
  - The row's width animates with the search field's `ShelfStyle.lift`, or not at all under Reduce Motion.

- [ ] **Step 4: Run tests and look**

Run: `scripts/test.sh ChipRowLayoutTests`
Expected: pass. Then build and run the app (`scripts/build_app.sh`). Make five collections, open and close the search, and narrow the window. Chips move into "N more" and back, and nothing overlaps the window buttons or the search.

- [ ] **Step 5: Commit**

```bash
git add Readme/Library/ChipRowLayout.swift Readme/Library/CollectionChips.swift Readme/Library/LibraryView.swift ReadmeTests/ChipRowLayoutTests.swift
git commit -m "feat: chip row for collections on the search line"
```

### Task 4: Adding books, and naming collections

**Files:**
- Create: `Readme/Library/CollectionNameSheet.swift`
- Modify: `Readme/Library/ShelfRow.swift` (`ShelfBook` context menu), `Readme/Library/ShelfSelection.swift`, `Readme/Library/LibraryView.swift` (`.sheet(item: $collections.sheet)`)
- Test: `ReadmeTests/ShelfSelectionTests.swift`, `ReadmeTests/CollectionNameSheetTests.swift`

**Interfaces:**
- Consumes: `ShelfCollections` (environment object), `LibraryStore` collection API, `selection.targets(rightClicked:order:)`, `BookCollection.suggestions(excluding:)`.
- Produces:
  - `static func ShelfSelection.isEveryBook(_ books: [Book], in collection: UUID) -> Bool`
  - `static func ShelfSelection.removeFromTitle(name: String) -> String`, which gives "Remove from <name>"
  - `struct CollectionNameSheet: View`, built from a `CollectionSheet` and a `LibraryStore`
  - `static func CollectionNameSheet.addsLine(count: Int) -> String?`: nil for 0, "Adds this book." for 1, "Adds the N selected books." otherwise.
  - `static func CollectionNameSheet.renameConflict(_ name: String, renaming id: UUID, in collections: [BookCollection]) -> String?`, which gives "There's already a collection called <Name>." or nil.

- [ ] **Step 1: Write the failing tests**
  - In `ShelfSelectionTests`, add `collectionCheckmark`. For one book in X, `isEveryBook == true`. For two books both in X, true. For a mixed pair, false. For an empty list, false. Also, `removeFromTitle(name: "Self-Help") == "Remove from Self-Help"`.
  - In `CollectionNameSheetTests`:
    - `addsLine(count: 0) == nil`, `(1) == "Adds this book."`, `(2) == "Adds the 2 selected books."`
    - `renameConflict("fiction", renaming: historyID, in: [Fiction, History])` gives the "already" line.
    - `renameConflict("FICTION", renaming: fictionID, ...)` is nil.

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test.sh ShelfSelectionTests`, `scripts/test.sh CollectionNameSheetTests`
Expected: build failures.

- [ ] **Step 3: Implement**
  - **`ShelfBook.contextMenu`**, in the order Global Constraints gives.
    - "Remove from <Name>" calls `setCollection(active, member: false, ids: targets)`.
    - "Add to Collection" is a `Menu`. Each collection is a `Toggle`, on when `isEveryBook`; choosing it sets membership for all targets to the opposite of "every book is in". Then a `Divider`, then "New Collection…", which sets `sheet = .create(bookIDs: targets)`.
    - Built-in VoiceOver context-menu access covers it, so no new accessibility actions are needed.
  - **`CollectionNameSheet`**
    - Title: "New Collection", or "Rename Collection".
    - A name `TextField` limited to `BookCollection.maxNameLength`, starting with the current name when renaming.
    - Create mode only: suggestion capsules under "Suggestions" that fill the field when clicked.
    - `addsLine`, then Cancel and a default Create/Save button, disabled when `cleanName` is nil or, when renaming, when `renameConflict` is non-nil.
    - Create calls `createCollection`, then `setCollection(..., member: true, ids: bookIDs)`.
    - Styled in the shelf palette, as in the mockup: `ShelfStyle.top` background, `ShelfStyle.title(26)` heading.

- [ ] **Step 4: Run tests and look**

Run: `scripts/test.sh ShelfSelectionTests`, `scripts/test.sh CollectionNameSheetTests`
Expected: pass. Then, in the app:
  - Right-click one book and a ⌘-selection: the checkmarks follow the rules, and New Collection… makes a collection with the books in it.
  - With a chip active, "Remove from" is at the top and takes the book off the filtered shelf.

- [ ] **Step 5: Commit**

```bash
git add Readme/Library/CollectionNameSheet.swift Readme/Library/ShelfRow.swift Readme/Library/ShelfSelection.swift Readme/Library/LibraryView.swift ReadmeTests/ShelfSelectionTests.swift ReadmeTests/CollectionNameSheetTests.swift
git commit -m "feat: add books to collections and name them"
```

### Task 5: Collections in bundles

**Files:**
- Modify: `Readme/Library/LibraryBundle.swift` (`BundledBook`), `Readme/Library/LibraryExporter.swift`, `Readme/Library/LibraryImporter.swift`, `docs/readmelibrary-format.md`
- Test: `ReadmeTests/LibraryBundleTests.swift`, `ReadmeTests/LibraryImporterTests.swift`

**Interfaces:**
- Consumes: `LibraryStore.collection(id:)`, `joinCollections(named:id:)`.
- Produces: `BundledBook.collections: [String]? = nil`

- [ ] **Step 1: Write the failing tests**
  - In `LibraryBundleTests`, add `collectionsKeyLeftOutWhenNone`. Encode a `BundledBook` with `collections: nil`, and the JSON has no `"collections"` key. Decoding `{"title":…,"addedAt":…}` with no key gives `collections == nil`.
  - In `LibraryImporterTests`, give `exportFromA` a `collections: [String] = []` parameter that joins them on A before exporting, then add:
    - `newBooksJoinTheirCollections`: A has ["Self-Help", "Investing"]. After importing on B with `.keepMine`, B has both collections and the book is in both.
    - `namesMatchAcrossCase`: B already has "investing". Importing a book in "INVESTING" leaves B with one such collection, and the book is in it.
    - `combineGivesTheUnion`: the book is in "Fiction" on B and in "History" on A. After `.combine` it's in both.
    - `keepMineLeavesCollectionsAlone`: the same setup with `.keepMine` leaves it only in "Fiction".
    - `bundleWithoutCollections`: a book exported with none imports with `collectionIDs == []`, and no collections are made.

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test.sh LibraryBundleTests`, `scripts/test.sh LibraryImporterTests`
Expected: build failures, then assertion failures.

- [ ] **Step 3: Implement**
  - The exporter maps `book.collectionIDs` to names through `store.collection(id:)`, sorted, and nil when empty.
  - In `LibraryImporter.add`, after `restorePin`, call `store.joinCollections(named:id:)`. Do the same in `combine`.
  - Add the row to the `book.json` table in `docs/readmelibrary-format.md`: `collections` | array of strings, optional | Names of the collections it's in, matched ignoring case and accents. Absent when it's in none, and in bundles from before collections.

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh LibraryBundleTests`, `scripts/test.sh LibraryImporterTests`, `scripts/test.sh GoldenFilesTests`
Expected: all pass. Golden bundles without the key still read.

- [ ] **Step 5: Commit**

```bash
git add Readme/Library/LibraryBundle.swift Readme/Library/LibraryExporter.swift Readme/Library/LibraryImporter.swift docs/readmelibrary-format.md ReadmeTests/LibraryBundleTests.swift ReadmeTests/LibraryImporterTests.swift
git commit -m "feat: carry collections in library bundles"
```

### Task 6: Windows follow-up and the whole suite

**Files:**
- Modify: `docs/Readme for Windows checklist.md`

- [ ] **Step 1:** Under "Mac features added since the plan", add an unticked **Collections** item. Say that it changes the shared contract (`collections`, a list of names, on `BundledBook`), and that it must land on Windows before the next release, or a library going Mac → Windows → Mac loses its collections. Point it at the spec's "Windows port" section. Update **Current state** to mention it.
- [ ] **Step 2:** Run the whole suite: `scripts/test.sh`. Expected: no failures, apart from any test already known to be flaky on `main`, which must be named in the report.
- [ ] **Step 3:** Check by hand in the built app:
  - VoiceOver reads a chip as "Self-Help, collection, selected".
  - Esc steps back through search, then selection, then All.
  - A book dropped while a chip is active stays in view.
  - Quitting and relaunching opens on All, with the collections kept.
- [ ] **Step 4: Commit**

```bash
git add "docs/Readme for Windows checklist.md"
git commit -m "docs: collections on the Windows checklist"
```
