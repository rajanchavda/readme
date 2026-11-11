# Export and Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export the whole library, or the books selected on the shelf, to one `.readmelibrary` file holding each book's EPUB, highlights, marker and place, and import such a file on another Mac without ever replacing a book that's already there.

**Architecture:** A bundle is a plain zip with stored (uncompressed) entries. A new `ZipWriter` writes it, and the existing `ZipArchive` (in `EPUBInspector.swift`) reads it. `LibraryBundle` defines the layout and its JSON, `LibraryExporter` builds a bundle from the stores, and `LibraryImporter` reads one in two phases. `prepare` sorts the books into new and already-here. `run` imports new books through the existing `BookImporter`, then writes their notes through the stores. With `combine`, it also merges into the books already here. The app layer adds shelf selection, the File menu items, the save and open panels, the Keep Mine / Combine / Cancel question, and the quiet notices.

**Tech Stack:** Swift 6, SwiftUI and AppKit, Swift Testing, xcodegen. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-11-export-import-design.md`

## Global Constraints

- macOS 14 or later, Apple silicon. Swift 6 strict concurrency. No third-party dependencies.
- The file extension is `.readmelibrary`. The UTI is `com.rajanchavda.Readme.library`, conforming to `public.data` and `public.archive`.
- `BundleManifest.currentVersion = 1`. A bundle with a higher `formatVersion` is refused, never partly read.
- No ZIP64. Any offset or size of `0xFFFF_FFFF` or more, or 65,535 or more entries, throws `ZipWriter.Failure.tooLarge`, and the partly written file is deleted.
- Book IDs read from a bundle must be 64 lowercase hex characters. Anything else makes the bundle `notABundle`. These IDs become file paths.
- Existing on-disk formats are unchanged: `library.json`, `Books/`, `Covers/`, `Highlights/`, `Markers/`, `Positions/`, `LastSpreads/`.
- Importing never replaces a book file already in the library. All writes go through `LibraryStore`, `HighlightStore`, `MarkerStore` and `PositionStore`.
- Settings are never exported. The bundle holds no paths from the exporting Mac.
- All bundle JSON uses ISO 8601 dates (`.iso8601`).
- Exact text (tests pin these):
  - Question: `"This book is already in your library."` (when the bundle holds one book), `"1 of these books is already in your library."`, `"3 of these books are already in your library."`. Informative text: `"Keep Mine leaves your copy as it is. Combine adds the highlights you don't have and keeps whichever reading place is further along. Your copy of the book is never replaced."` Buttons, in order: `"Keep Mine"` (default), `"Combine"`, `"Cancel"`.
  - Import summary: parts joined by `", "`, first letter capitalized, zero counts left out: `"added 1 book"` / `"added 4 books"`, `"combined 2"`, `"left 2 as they were"`, `"1 couldn't be read"`. Example: `"Added 4 books, combined 2, 1 couldn't be read"`. All zero: `"Nothing to import"`.
  - Export summary: `"Exported 1 book"` / `"Exported 12 books"`, plus `", 1 was missing and left out"` or `", 2 were missing and left out"`.
  - Errors: `notABundle` gives `"This file isn't a Readme library."`, `newerVersion` gives `"This library was made by a newer Readme. Update Readme to import it."`, `tooLarge` gives `"That's more than 4 GB, too much for one file. Export fewer books at a time."`, and any other export failure gives `"The export couldn't be saved."`
  - Progress: `"Exporting 12 books…"` and `"Importing 12 books…"` (`"…1 book…"` when there's one).
  - Menu items in the File menu after "Open…": `"Import…"` and `"Export Library…"`, with no shortcuts. Context menu: `"Export…"`, or `"Export 3 Books…"` for a selection of more than one.
- Run tests with `scripts/test.sh [Suite]`.
- Commits end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```

## Review Focus

1. **The open book gets combined.** The reader's in-memory place is written by `PlaceWriter`, `ReadMarker` and `keepPlace()` on quit, and it must not overwrite the further place the import just saved. The open book is closed before the merge, so the next open lands on the merged place. Test: `combiningTheOpenBookClosesItAndKeepsTheImportedPlace` (Task 8).
2. **A bundle with one bad book.** It's copy-protected, not an EPUB, or its hash doesn't match its ID. That book counts as failed, and the others still come in. Tests: `aBadBookInTheBundleIsSkipped` and `aBookWhoseFileDoesntMatchItsIDIsSkipped` (Task 5).
3. **The same bundle imported twice.** There must be no duplicate books or highlights, and nothing changes the second time. Test: `importingTwiceChangesNothing` (Task 5).
4. **Exporting over an existing file chosen with "Replace" in the save panel.** The writer must truncate, never leave old bytes after the new end record. Test: `overwritesAnExistingFile` (Task 1).
5. **A hostile bundle with IDs like `../../x`.** These must never become paths outside the staging folder. Test: `rejectsIDsThatArentHashes` (Task 2).

---

### Task 1: Stored zip writer

**Files:**
- Create: `Readme/Library/ZipWriter.swift`
- Modify: `Readme/Library/EPUBInspector.swift` (`ZipArchive`: add `names`)
- Test: `ReadmeTests/ZipWriterTests.swift`

**Interfaces:**
- Produces:
  - `enum CRC32 { static func checksum(_ data: Data) -> UInt32 }`. IEEE polynomial `0xEDB88320`, table-driven.
  - `final class ZipWriter`:
    - `init(url: URL, limit: UInt64 = 0xFFFF_FFFE) throws` creates or truncates the file.
    - `func add(_ name: String, data: Data) throws`
    - `func add(_ name: String, contentsOf file: URL) throws`
    - `func finish() throws`
    - `enum Failure: Error, Equatable { case tooLarge, unwritable }`
  - `ZipArchive.names: [String]`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func crcOfTheStandardCheckString() {
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
}
@Test func roundTripsThroughZipArchive() throws {
    // add "a.json" (data) and "books/x/book.epub" (contentsOf: fixture long.epub), finish
    let archive = try #require(ZipArchive(url))
    #expect(Set(archive.names) == ["a.json", "books/x/book.epub"])
    #expect(archive.data(for: "a.json", limit: 1 << 20) == Data(#"{"k":1}"#.utf8))
    #expect(archive.data(for: "books/x/book.epub", limit: 1 << 30) == (try Data(contentsOf: fixture("long.epub"))))
}
@Test func overwritesAnExistingFile() throws {
    // write 1 MB of 0xFF to url first, then a one-entry zip to the same url
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int < 1024)
    #expect(ZipArchive(url) != nil)
}
@Test func tooLargeFailsAndLeavesNoFile() throws {
    let writer = try ZipWriter(url: url, limit: 100)
    #expect(throws: ZipWriter.Failure.tooLarge) { try writer.add("big", data: Data(count: 200)) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
```

- [ ] **Step 2: Run them to see them fail.** Run `scripts/test.sh ZipWriterTests`. Expected: build failure, because `ZipWriter` doesn't exist yet.

- [ ] **Step 3: Implement `ZipWriter` and `CRC32`.**
  - Write a local file header for each entry: signature `0x04034b50`, version 20, flags `0x0800` (UTF-8 names), method 0, DOS time and date 0, CRC, then the size twice. The data follows directly, with no data descriptor.
  - Keep the central-directory records in memory, and write them plus the end record in `finish()`.
  - `add(_:contentsOf:)` reads the file into `Data`. EPUBs are small.
  - Before each write, check that `offset + 30 + name + size` and the final directory end stay within `limit`, and that there are fewer than 65,535 entries. Otherwise close the file, delete it and throw `.tooLarge`.
  - Wrap I/O errors as `.unwritable`, deleting the file.
  - Add `ZipArchive.names` as `Array(entries.keys)`.

- [ ] **Step 4: Run them to see them pass.** Run `scripts/test.sh ZipWriterTests`. Expected: all pass.

- [ ] **Step 5: Commit** with the message `feat: write stored zips`.

---

### Task 2: The bundle format

**Files:**
- Create: `Readme/Library/LibraryBundle.swift`
- Test: `ReadmeTests/LibraryBundleTests.swift`

**Interfaces:**
- Consumes: `ZipWriter` and `ZipArchive.names` from Task 1. `Highlight`, `Marker` and `ReaderLocation` (all `Codable`).
- Produces:
  - `struct BundleManifest: Codable, Equatable`, with `formatVersion: Int`, `exportedAt: Date` and `bookIDs: [String]`. Also `static let currentVersion = 1`.
  - `struct BundledBook: Codable, Equatable`, with `title: String`, `author: String?`, `addedAt: Date` and `lastReadAt: Date?`.
  - `struct BundleItem: Sendable`, with `id: String`, `info: BundledBook`, `epub: URL`, `highlights: [Highlight]`, `marker: Marker?` and `position: ReaderLocation?`.
  - `struct BundleContents: Equatable`, with `info: BundledBook`, `highlights: [Highlight]`, `marker: Marker?` and `position: ReaderLocation?`.
  - `enum BundleError: Error, Equatable { case notABundle, newerVersion, tooLarge, unwritable }` with `var message: String`, using the exact text from Global Constraints. `unwritable` gives `"The export couldn't be saved."`
  - `enum LibraryBundle`:
    - `static func write(_ items: [BundleItem], to url: URL, exportedAt: Date) throws(BundleError)` maps `ZipWriter.Failure`.
    - `static func open(_ url: URL) throws(BundleError) -> OpenedBundle`
  - `struct OpenedBundle: Sendable`:
    - `let url: URL`
    - `let manifest: BundleManifest`
    - `func contents(of id: String) throws(BundleError) -> BundleContents`
    - `func extractEPUB(of id: String, to destination: URL) throws(BundleError)`

Layout, as in the spec:
- `manifest.json`
- For each book, `books/<id>/` holds:
  - `book.json`
  - `book.epub`
  - `highlights.json`
  - `marker.json` (left out when there's none)
  - `position.json` (left out when there's none)

`open` checks the following, or throws `.notABundle`:
- `manifest.json` decodes.
- `formatVersion > currentVersion` throws `.newerVersion`.
- Every ID matches `^[0-9a-f]{64}$`.
- `books/<id>/book.json` and `books/<id>/book.epub` exist for every listed ID.

Also, a missing `highlights.json` reads as `[]`. Use a 2 GB `limit` for `book.epub` and 64 MB for the JSON files.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func roundTripsEveryPart() throws {
    // item with 2 highlights, a marker and a position, epub = fixture long.epub, id = its BookID
    let opened = try LibraryBundle.open(url)
    #expect(opened.manifest.bookIDs == [id] && opened.manifest.formatVersion == 1)
    #expect(try opened.contents(of: id) == BundleContents(info: info, highlights: two, marker: marker, position: place))
    try opened.extractEPUB(of: id, to: out)
    #expect(try Data(contentsOf: out) == (try Data(contentsOf: fixture("long.epub"))))
}
@Test func noMarkerOrPositionReadsAsNil()        // contents(of:).marker == nil, .position == nil
@Test func refusesANewerVersion()                // hand-written zip with formatVersion 2 → throws .newerVersion
@Test func anEPUBIsNotABundle()                  // open(fixture "long.epub") → throws .notABundle
@Test func rejectsIDsThatArentHashes()           // manifest bookIDs ["../../x"] → throws .notABundle
@Test func aListedBookWithoutItsFileIsNotABundle()
```

- [ ] **Step 2: Run them to see them fail.** Run `scripts/test.sh LibraryBundleTests`. Expected: build failure.
- [ ] **Step 3: Implement `LibraryBundle.swift`** to the interfaces above.
- [ ] **Step 4: Run them to see them pass.** Run `scripts/test.sh LibraryBundleTests`. Expected: all pass.
- [ ] **Step 5: Commit** with the message `feat: the .readmelibrary bundle format`.

---

### Task 3: Merging into the stores

**Files:**
- Modify:
  - `Readme/Library/HighlightStore.swift`
  - `Readme/Library/MarkerStore.swift`
  - `Readme/Library/LibraryStore.swift`
  - `Readme/Library/PositionStore.swift`
- Test: add cases to `ReadmeTests/HighlightStoreTests.swift`, `MarkerStoreTests.swift`, `LibraryStoreTests.swift` and `PositionStoreTests.swift`.

**Interfaces:**
- Produces:
  - `HighlightStore.merge(_ incoming: [Highlight], bookID: String) -> Int` adds those whose `id` and `cfi` are both new. It writes once and returns the number added. Nothing already there changes.
  - `MarkerStore.setIfNone(_ marker: Marker, bookID: String) -> Bool`
  - `enum ImportMerge { static func isFurther(_ incoming: ReaderLocation, than existing: ReaderLocation?) -> Bool }` is true when `existing == nil` or `incoming.fraction > existing.fraction`. Put it in `PositionStore.swift`.
  - `LibraryStore.positions` changes from `private let` to `let`.
  - `LibraryStore.applyImported(id: String, addedAt: Date?, lastReadAt: Date?, location: ReaderLocation?)`:
    - sets `addedAt` when it's given
    - sets `lastReadAt` to the later of the current value and the given one (nil counts as earliest)
    - copies `chapterTitle` and `chapterMinutesLeft` from `location` when it's given
    - saves
    - does nothing for an unknown ID

- [ ] **Step 1: Write the failing tests**

```swift
@Test func mergeAddsOnlyWhatsNew() async {
    // store has A(id a, cfi 1); merge [A, B(id a2, cfi 1), C(new id, new cfi)] → returns 1; highlights == [A, C]
}
@Test func setIfNoneKeepsAnExistingMarker()     // set m1; setIfNone(m2) == false; marker == m1
@Test func setIfNoneSetsWhenThereIsNone()       // == true; marker == m2
@Test func furtherIsByFraction() {
    #expect(ImportMerge.isFurther(place(0.6), than: place(0.4)))
    #expect(!ImportMerge.isFurther(place(0.4), than: place(0.4)))
    #expect(ImportMerge.isFurther(place(0.1), than: nil))
}
@Test func applyImportedKeepsTheLaterReadDate()  // read at 200, apply lastReadAt 100 → 200; apply 300 → 300
@Test func applyImportedSetsAddedAtAndChapter()  // addedAt 50 → 50; location chapter "Two", minutes 3 → copied
```

- [ ] **Step 2: Run them to see them fail.** Run `scripts/test.sh HighlightStoreTests` and the other three suites. Expected: build failure.
- [ ] **Step 3: Implement the five members above.**
- [ ] **Step 4: Run them to see them pass.** Run the same four suites. Expected: all pass.
- [ ] **Step 5: Commit** with the message `feat: merge imported notes into the stores`.

---

### Task 4: Exporter

**Files:**
- Create: `Readme/Library/LibraryExporter.swift`
- Test: `ReadmeTests/LibraryExporterTests.swift`

**Interfaces:**
- Consumes: `LibraryBundle.write` (Task 2) and `LibraryStore.positions` (Task 3).
- Produces:
  - `struct ExportSummary: Equatable` with `exported: Int`, `missing: Int` and `var line: String`.
  - `@MainActor struct LibraryExporter`, with `let store: LibraryStore` and `func export(_ books: [Book], to url: URL, now: Date = Date()) async throws(BundleError) -> ExportSummary`.

For each book:
- Gather its file URL, `BundledBook` (from `Book`), highlights, marker and position, all from `store`.
- Leave out books whose file doesn't exist, counting them as `missing`.
- If none are left, throw `.unwritable`.

Write the bundle off the main actor (`Task.detached`). The caller handles the security scope of `url`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func exportsBooksWithTheirNotes() async throws {
    // import long.epub into a temp library, add a highlight, set a marker, save a position
    let summary = try await LibraryExporter(store: store).export(store.books, to: url)
    #expect(summary == ExportSummary(exported: 1, missing: 0))
    let contents = try LibraryBundle.open(url).contents(of: book.id)
    #expect(contents.highlights.count == 1 && contents.marker != nil && contents.position != nil)
    #expect(contents.info.title == "Long Fixture Book")
}
@Test func aMissingFileIsLeftOutAndCounted()     // delete one book's copy → ExportSummary(exported: 1, missing: 1)
@Test func summaryLines() {
    #expect(ExportSummary(exported: 1, missing: 0).line == "Exported 1 book")
    #expect(ExportSummary(exported: 12, missing: 2).line == "Exported 12 books, 2 were missing and left out")
    #expect(ExportSummary(exported: 3, missing: 1).line == "Exported 3 books, 1 was missing and left out")
}
```

- [ ] **Step 2: Run them to see them fail.** Run `scripts/test.sh LibraryExporterTests`. Expected: build failure.
- [ ] **Step 3: Implement `LibraryExporter`.**
- [ ] **Step 4: Run them to see them pass.** Run `scripts/test.sh LibraryExporterTests`. Expected: all pass.
- [ ] **Step 5: Commit** with the message `feat: export books with their notes`.

---

### Task 5: Importer

**Files:**
- Create: `Readme/Library/LibraryImporter.swift`
- Test: `ReadmeTests/LibraryImporterTests.swift`

**Interfaces:**
- Consumes:
  - `LibraryBundle.open`, `OpenedBundle` (Task 2)
  - the merge members (Task 3)
  - `LibraryExporter` (Task 4), used to build bundles in the tests
  - `BookImporter.importBook(from:)` and `BookID.of(_:)`, both existing
- Produces:
  - `struct PreparedImport: Sendable`, with `bundle: OpenedBundle`, `newIDs: [String]` and `existingIDs: [String]`, each in manifest order.
  - `enum ImportChoice: Sendable { case keepMine, combine }`
  - `struct ImportSummary: Equatable`, with `added`, `combined`, `kept` and `failed` (all `Int`, defaulting to 0) and `var line: String`, using the exact text from Global Constraints.
  - `@MainActor struct LibraryImporter`:
    - `init(store: LibraryStore, importer: BookImporter)`
    - `func prepare(_ url: URL) async throws(BundleError) -> PreparedImport` opens the bundle off the main actor inside the URL's security scope.
    - `func run(_ prepared: PreparedImport, choice: ImportChoice) async -> ImportSummary`

`run` holds the security scope of `prepared.bundle.url` throughout.

**For each new ID:**
1. Extract the EPUB to `store.booksDirectory/.bundle-<UUID>.epub`, and always delete it afterwards.
2. If `BookID.of(staged) != id`, count it as `failed`.
3. Call `importer.importBook(from: staged)`. A thrown error counts as `failed`.
4. Call `store.applyImported(id:addedAt: info.addedAt, lastReadAt: info.lastReadAt, location: position)`.
5. Call `highlights.merge`, then `markers.setIfNone` if there's a marker, then `positions.save` if there's a position.
6. Count it as `added`.

**For each existing ID:**
- With `keepMine`, count it as `kept` and touch nothing.
- With `combine`:
  1. Call `highlights.merge` and `markers.setIfNone`.
  2. If `ImportMerge.isFurther(incoming, than: await positions.location(bookID:))`, save the incoming place.
  3. Call `applyImported(id:addedAt: nil, lastReadAt: info.lastReadAt, location: further ? incoming : nil)`.
  4. Remove `store.spreads` for the book, since its last-spread picture is stale.
  5. Count it as `combined`.

A failure reading one book's contents counts that book as `failed` and carries on. A book that `prepare` saw as new but that's already in the library by the time `run` reaches it (a race) is handled as existing.

- [ ] **Step 1: Write the failing tests.** Each test exports from library A and imports into a fresh library B, using `long.epub` and `search.epub`.

```swift
@Test func newBooksComeInWithEverything() async throws {
    // A: long.epub with highlight h, marker m, position p (fraction 0.5), addedAt 1000, read at 2000
    let prepared = try await importerB.prepare(url)
    #expect(prepared.newIDs == [id] && prepared.existingIDs.isEmpty)
    #expect(await importerB.run(prepared, choice: .keepMine) == ImportSummary(added: 1))
    #expect(storeB.book(id: id)?.addedAt == date(1000) && storeB.book(id: id)?.lastReadAt == date(2000))
    #expect(await storeB.highlights.highlights(bookID: id) == [h])
    #expect(await storeB.markers.marker(bookID: id) == m)
    #expect(await storeB.positions.location(bookID: id) == p)
    #expect(FileManager.default.fileExists(atPath: storeB.coverURL(for: storeB.book(id: id)!).path))
}
@Test func keepMineLeavesExistingBooksAlone()   // B has the book with h2 and place 0.2; keepMine → kept 1, B unchanged
@Test func combineAddsHighlightsAndTheFurtherPlace() // B: h2, place 0.2, marker m2 → highlights [h, h2], place p(0.5), marker m2, combined 1
@Test func combineKeepsTheFurtherPlaceHere()    // B place 0.9 → stays 0.9
@Test func importingTwiceChangesNothing()       // new import, then combine again → same books, highlight count unchanged
@Test func aBadBookInTheBundleIsSkipped()       // bundle via LibraryBundle.write of [drm.epub (id = its hash), long.epub] → ImportSummary(added: 1, failed: 1)
@Test func aBookWhoseFileDoesntMatchItsIDIsSkipped() // item id = 64 × "a", epub long.epub → failed 1, library empty
@Test func noLeftoverStagingFiles()             // after any run, booksDirectory holds no ".bundle-" files
@Test func summaryLines() {
    #expect(ImportSummary(added: 4, combined: 2, failed: 1).line == "Added 4 books, combined 2, 1 couldn't be read")
    #expect(ImportSummary(added: 1).line == "Added 1 book")
    #expect(ImportSummary(kept: 2).line == "Left 2 as they were")
    #expect(ImportSummary().line == "Nothing to import")
}
```

- [ ] **Step 2: Run them to see them fail.** Run `scripts/test.sh LibraryImporterTests`. Expected: build failure.
- [ ] **Step 3: Implement `LibraryImporter`.**
- [ ] **Step 4: Run them to see them pass.** Run `scripts/test.sh LibraryImporterTests`. Expected: all pass.
- [ ] **Step 5: Commit** with the message `feat: import bundles without replacing books`.

---

### Task 6: Selecting books on the shelf

**Files:**
- Create: `Readme/Library/ShelfSelection.swift`
- Modify:
  - `Readme/Library/ShelfRow.swift` (`ShelfBook`)
  - `Readme/Library/CurrentBookShelf.swift`
  - `Readme/Library/LibraryView.swift`
- Test: `ReadmeTests/ShelfSelectionTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class ShelfSelection: ObservableObject`:
    - `@Published private(set) var ids: Set<String>`
    - `enum Outcome { case open, changed }`
    - `func click(_ id: String, modifiers: NSEvent.ModifierFlags, order: [String]) -> Outcome`
    - `func clear()`
    - `func targets(rightClicked id: String, order: [String]) -> [String]`
    - `func menuTitle(rightClicked id: String) -> String`
  - `LibraryView` gains `selection: ShelfSelection` and `onExport: ([Book]) -> Void`. Keep the `previewing:` initializer working with a fresh `ShelfSelection()` and a no-op `onExport`.

**Rules:**
- **A plain click** clears the selection and returns `.open`.
- **⌘-click** toggles the book, makes it the anchor and returns `.changed`.
- **Shift-click** selects the run from the anchor to the book in `order`, replacing the selection. With no anchor, it selects just the book and makes it the anchor. It returns `.changed`.
- **`targets`** gives the selection in `order` when it contains `id`, and otherwise `[id]`.
- **`menuTitle`** gives `"Export \(n) Books…"` when `id` is in a selection of more than one, and otherwise `"Export…"`.
- **`order`** is `[library.current] + library.others`, which is the order the shelf shows.

**View wiring:**
- `ShelfBook`'s button action reads `NSEvent.modifierFlags` and calls `selection.click`. On `.open`, it calls `onOpen`.
- A selected cover gets `.overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 3))`.
- The context menu gains the export item above "Remove". It calls `onExport` with the target books.
- A tap on empty shelf space (`.contentShape(Rectangle()).onTapGesture`, behind the books) calls `clear()`.
- Esc is wired in Task 7.

- [ ] **Step 1: Write the failing tests**

```swift
let order = ["a", "b", "c", "d"]
@Test func plainClickOpensAndClears()     // cmd-click a; click(b, []) == .open; ids == []
@Test func commandClickToggles()          // cmd a, cmd c → {a, c}; cmd a → {c}; outcomes .changed
@Test func shiftClickSelectsTheRun()      // cmd b; shift d → {b, c, d}; shift a → {a, b}
@Test func shiftClickWithoutAnchorSelectsOne() // shift c → {c}
@Test func targetsFollowTheSelection() {
    // cmd c, cmd a → targets(rightClicked: "a") == ["a", "c"]; targets(rightClicked: "b") == ["b"]
    // menuTitle("a") == "Export 2 Books…"; menuTitle("b") == "Export…"
}
```

- [ ] **Step 2: Run them to see them fail.** Run `scripts/test.sh ShelfSelectionTests`. Expected: build failure.
- [ ] **Step 3: Implement `ShelfSelection`, then wire the views as above.**
- [ ] **Step 4: Run the tests to see them pass.** Run `scripts/test.sh ShelfSelectionTests` and `scripts/test.sh ShelfLayoutTests`. Expected: all pass.
- [ ] **Step 5: Commit** with the message `feat: select books on the shelf`.

---

### Task 7: Export in the app

**Files:**
- Modify:
  - `project.yml`: add `UTExportedTypeDeclarations` for `com.rajanchavda.Readme.library` (extension `readmelibrary`, description `Readme Library`, conforms to `public.data` and `public.archive`), and a second `CFBundleDocumentTypes` entry (`Readme Library`, role `Viewer`, rank `Owner`).
  - `Readme/Readme.entitlements`: change `com.apple.security.files.user-selected.read-only` to `.read-write`.
  - `Readme/App/ReadmeApp.swift`: menu items and `AppDelegate` passthroughs.
  - `Readme/App/AppCoordinator.swift`: `AppState.hasBooks`, export flow, wiring the selection and Esc.
  - `Readme/Reader/ReaderWindowController.swift`: save panel, Esc over the library.
  - `Readme/Library/ShelfDrops.swift`: free-text notice and a progress line.
- Test: `ReadmeTests/ExportFlowTests.swift`

**Interfaces:**
- Consumes: `LibraryExporter` (Task 4), `ShelfSelection` and `LibraryView(selection:onExport:)` (Task 6).
- Produces:
  - `extension UTType { static let readmeLibrary = UTType(exportedAs: "com.rajanchavda.Readme.library") }` in `LibraryBundle.swift`.
  - In `ShelfDrops`:
    - `func say(_ line: String)` shows a line with the same fade as failures.
    - `@Published private(set) var working: String?` and `func setWorking(_ line: String?)`. `NoticeView` shows `working` in the place of the `adding` line.
  - `ReaderWindowController.chooseExportDestination(suggestedName: String) async -> URL?` opens an `NSSavePanel` sheet with `allowedContentTypes = [.readmeLibrary]`.
  - `ReaderWindowController.onLibraryEscape: (() -> Void)?` is called from `handle(_:)` for keyCode 53 while `isShowingLibrary` and no sheet is attached.
  - In `AppCoordinator`:
    - `let selection: ShelfSelection`
    - `func exportLibrary()`
    - `func export(_ books: [Book]) async`, with `destination: URL?` passed through in tests to skip the panel.
  - `AppState.hasBooks: Bool` is kept up to date from `library.$books`.
  - Menu: `CommandGroup(after: .newItem) { Button("Import…"); Button("Export Library…").disabled(!state.hasBooks) }`. The menu observes `appDelegate.state`. "Import…" calls `appDelegate.importBundle()` (Task 8). Until then, add it as a stub that shows the window.

**Export flow:**
1. The suggested name is `"Readme Library"` for the whole library, and `book.title` for one book. For several books, it's `"Readme Library"`.
2. Get the destination and hold its security scope.
3. Call `drops.setWorking("Exporting N books…")`.
4. Run the export, then clear the working line.
5. Call `drops.say(summary.line)`, or `drops.say(error.message)` on failure.
6. Clear the selection.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func exportWritesTheChosenBooks() async throws {
    // coordinator over a temp library with long.epub + search.epub; export([long], destination: url)
    #expect(try LibraryBundle.open(url).manifest.bookIDs == [long.id])
    #expect(coordinator.drops.lines == ["Exported 1 book"])
}
@Test func hasBooksFollowsTheLibrary()         // empty → false; after import → true; after remove → false
@Test func escapeOverTheLibraryClearsTheSelection() // select a book, call reader.onLibraryEscape?() → selection.ids.isEmpty
```

- [ ] **Step 2: Run them to see them fail.** Run `scripts/test.sh ExportFlowTests`. Expected: build failure.
- [ ] **Step 3: Implement the changes in the files listed above.**
- [ ] **Step 4: Run the tests to see them pass.** Run `scripts/test.sh ExportFlowTests`, then the whole suite with `scripts/test.sh`. Expected: all pass.
- [ ] **Step 5: Check by hand.** Build with `scripts/build_app.sh` and launch it. Check that:
  - File > Export Library… saves a `.readmelibrary` file.
  - Finder shows it as a document, not a folder.
  - ⌘-clicking two books, then right-clicking, shows "Export 2 Books…".
- [ ] **Step 6: Commit** with the message `feat: export the library or selected books`.

---

### Task 8: Import in the app

**Files:**
- Modify:
  - `Readme/App/AppCoordinator.swift`
  - `Readme/App/ReadmeApp.swift`
  - `Readme/Reader/ReaderWindowController.swift`
  - `Readme/Library/LibraryView.swift`
  - `README.md`
- Test: `ReadmeTests/ImportFlowTests.swift`

**Interfaces:**
- Consumes: `LibraryImporter`, `PreparedImport`, `ImportChoice` and `ImportSummary` (Task 5). `ShelfDrops.say` and `setWorking`, and `UTType.readmeLibrary` (Task 7).
- Produces:
  - `enum ImportQuestion { static func message(existing: Int, total: Int) -> String; static let informative: String; static let buttons = ["Keep Mine", "Combine", "Cancel"] }`, in `AppCoordinator.swift`.
  - `ReaderWindowController.askImportChoice(existing: Int, total: Int) async -> ImportChoice?` opens an `NSAlert` sheet. The first button is `keepMine`, the second is `combine`, and the third is `nil` (Esc).
  - `ReaderWindowController.chooseBundle(_ chosen: @escaping ([URL]) -> Void)` opens an open panel with `[.readmeLibrary]`.
  - In `AppCoordinator`:
    - `let libraryImporter: LibraryImporter`
    - `func chooseBundle()`
    - `func importBundles(_ urls: [URL], answer: ImportChoice?? = nil) async`. The `answer` parameter is for tests: when non-nil it's used instead of asking.
  - `AppDelegate.importBundle()`
  - `LibraryView` gains `onBundles: ([URL]) -> Void`. A drop splits its URLs by extension: `.readmelibrary` files go to `onBundles`, and the rest go to `drops.add` as now.
  - `AppCoordinator.open(_ urls:)` splits the same way. Bundles call `showLibrary()`, then `importBundles`. EPUBs go through the existing path.

**Import flow, for each bundle in turn:**
1. Show the library.
2. Call `prepare`. On error, call `drops.say(error.message)` and stop.
3. If `existingIDs` isn't empty, ask the question. If the answer is `nil` (Cancel), stop with nothing changed.
4. If the choice is `combine` and `existingIDs` contains `reader.currentRecordID`:
   1. Call `marker.flush()`.
   2. Call `await reader.placesKept()`.
   3. Call `reader.closeBook()`.

   This way nothing from the open reader can be written after the merge, and opening the book next lands on the merged place. The spec says the reader "moves to the new place". The book is behind the shelf, so it's reopened there the next time it's shown.
5. Call `drops.setWorking("Importing N books…")` and `run`, then clear the working line.
6. Call `drops.say(summary.line)`.

`README.md` gains a Features bullet: "**Export and import.** Take your books, with their highlights, page marker and place, to another Mac in one `.readmelibrary` file. Importing never replaces a book you already have."

- [ ] **Step 1: Write the failing tests**

```swift
@Test func questionText() {
    #expect(ImportQuestion.message(existing: 1, total: 1) == "This book is already in your library.")
    #expect(ImportQuestion.message(existing: 1, total: 4) == "1 of these books is already in your library.")
    #expect(ImportQuestion.message(existing: 3, total: 4) == "3 of these books are already in your library.")
}
@Test func cancelImportsNothing() async throws  // bundle [existing, new], answer: .some(nil) → library unchanged, no notice
@Test func allNewIsNotAsked() async throws       // answer: nil (would ask) on an all-new bundle → completes, "Added 1 book"
@Test func combiningTheOpenBookClosesItAndKeepsTheImportedPlace() async throws {
    // open long.epub in the reader at the start; bundle has it at fraction ≥ 0.5 with a new highlight
    await coordinator.importBundles([url], answer: .combine)
    #expect(coordinator.reader.openBook == nil)
    await coordinator.prepareToQuit()
    #expect(try #require(await positions.location(bookID: id)).fraction >= 0.5)
    #expect(await library.highlights.highlights(bookID: id).count == 1)
}
@Test func dropsAreSplitByKind()                // LibraryView routing helper: split([a.epub, b.readmelibrary]) == ([a], [b])
@Test func notABundleSaysSo()                   // a renamed .epub → drops.lines == ["This file isn't a Readme library."]
```

To make the drop routing testable, put it in `static func LibraryView.split(_ urls: [URL]) -> (books: [URL], bundles: [URL])`.

- [ ] **Step 2: Run them to see them fail.** Run `scripts/test.sh ImportFlowTests`. Expected: build failure.
- [ ] **Step 3: Implement the changes in the files listed above.**
- [ ] **Step 4: Run the tests to see them pass.** Run `scripts/test.sh ImportFlowTests`, then the whole suite with `scripts/test.sh`. Expected: all pass.
- [ ] **Step 5: Check by hand.** Build with `scripts/build_app.sh`. Export two books, remove one from the shelf, and highlight a new passage in the other. Then:
  - Double-click the bundle in Finder. The question should say "1 of these books is already in your library."
  - Choose Combine. The notice should read "Added 1 book, combined 1".
  - The kept book's highlights should include both old and new.
  - Import the bundle again with Keep Mine. The notice should read "Left 2 as they were".
- [ ] **Step 6: Commit** with the message `feat: import a library bundle`.
