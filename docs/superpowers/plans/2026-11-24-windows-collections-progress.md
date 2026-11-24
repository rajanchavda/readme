# Windows: Collections and Reading Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Mac's Collections and Reading progress to the Windows app, so a library moved between the two apps keeps its collections and finished books, and the Windows shelf works like the Mac's.

**Architecture:** As every earlier port: `Readme.Core` first, line for line with the Swift (it is the spec), with the Swift tests ported to MSTest; then the WinUI app on top. The Core tasks (1–5) build and test on the Mac with the .NET SDK. The app tasks (6–8) need the Windows machine.

**Tech Stack:** C# / .NET 10, MSTest (`Readme.Core.Tests`), WinUI 3 + Windows App SDK (`Readme.App`), System.Text.Json with the shared `Json.Library` / `Json.Iso` options.

**Specs:** `docs/superpowers/specs/2026-11-22-collections-design.md` and `docs/superpowers/specs/2026-11-22-reading-progress-design.md` (their "Windows port" sections). The Swift code on `main` is the reference for every name and rule: `Readme/Library/BookCollection.swift`, `ShelfCollections.swift`, `ShelfFilter.swift`, `ChipRowLayout.swift`, `CollectionChips.swift`, `CollectionNameSheet.swift`, `FinishRule.swift`, `ReadingMarks.swift`, `LibraryStore.swift`, `ShelfRow.swift`, and their tests.

## Global Constraints

- **The shared contract must match the Mac byte for byte in meaning.**
  - In `library.json`, the key is `collectionIDs` (capital `IDs`, so it needs `[JsonPropertyName]`, not the camel-case policy). It's written always, even when empty, as Swift does. `progress` (number) and `finishedAt` (reference-date seconds) are left out when null.
  - `collections.json` is an array of `{ "id": "<UPPERCASE UUID>", "name": …, "createdAt": <reference-date seconds> }`, written with `Json.Library`.
  - In `book.json` inside a `.readmelibrary`: `collections` (array of names, left out when empty) and `finishedAt` (ISO 8601 whole seconds, left out when null). `formatVersion` stays 1.
- **Collection names:**
  - Trimmed, at most 40 characters, never empty.
  - Unique, ignoring case and accents, compared with the same fold as `ShelfSearch`.
  - Suggestions: Fiction, Self-Help, Business, Investing, Biography, History, Philosophy, Spirituality, Science.
- **Finish rule:** threshold 0.95. Only page turns finish a book. A place reached while a jump (contents, Go to Page, Home/End, marker, search, highlights) or a link is landing is a jump. A jump is counted from when it starts moving the book, not when it's asked for, as fixed on the Mac after review.
- **Imports:**
  - Collections and finished dates only add up: an import never takes a book out of a collection, never unfinishes a book and never moves an existing date.
  - Keep Mine changes nothing on a book already here.
  - Books imported or dropped while a collection is showing join it.
- **Shelf look, all as on the Mac:**
  - Chips share the search's line: All, Reading, Finished (each hidden when empty), the collections A to Z, then **+**.
  - Chips that don't fit go into an "N more ▾" chip, and the active chip is always on the row.
  - Chips have a solid `#241F1A` background, the selected one is filled cream, and the shelf gets 36 pt of top padding while the row shows.
  - Covers get the progress bar (3 pt, 7 pt below the cover, track text at 0.10, fill ribbon colour at 0.85), the double tick on a corner shade, and a tooltip ("Title — Author", then "64% · Chapter 12" or "Finished 18 Nov").
  - Book menu order: Remove from X (when a collection is showing) and a separator, Add to Collection ▸, Export…, Pin to Front, Mark as Finished, a separator, Remove.
- **Version:** nothing to bump; `Package.appxmanifest` is already 1.8.10.0.
- **Rules for this repo:** never use the `gh` CLI. Temporary files go in `scratchpad/`. Tick the Windows checklist (`docs/Readme for Windows checklist.md`) as items are committed.

## Review Focus

1. A library made on the Mac (`collectionIDs` on books, `collections.json`) opens on Windows with its collections and finished books, and Windows writes it back so the Mac still reads it. Golden-file tests in Tasks 1–3.
2. A book pointing at a collection ID that isn't in `collections.json` drops it, but a `collections.json` that can't be read keeps every ID. Task 2.
3. A turn pressed while a jump is landing never makes the jump finish the book; going to the end never finishes it. Self-check in Task 6.
4. Under the Reading chip, finishing its last book sends the shelf to All and lets the filter go, so it doesn't come back on by itself. Task 5.
5. A chip row with more collections than fit: the active chip stays visible, and opening the search makes room. Task 5's `ChipRowLayout` tests, then by hand in Task 7.

---

### Task 1: Golden files carry the new fields

**Files:**
- Modify: `ReadmeTests/Fixtures/Golden/library.json`.
  - The long book gets `"collectionIDs":["4F2B6C1E-8C1A-4D2B-9E57-0C7A1B3D5E9F"]`, `"progress":0.42` and `"finishedAt":784700000`.
  - The other book gets `"collectionIDs":[]` and no progress.
- Create: `ReadmeTests/Fixtures/Golden/collections.json`, `[{"id":"4F2B6C1E-8C1A-4D2B-9E57-0C7A1B3D5E9F","name":"Self-Help","createdAt":784050000}]`.
- Modify: `ReadmeTests/Fixtures/Golden/README.md`, adding a `collections.json` row and naming the new keys.
- Modify: `ReadmeTests/GoldenFilesTests.swift`, `windows/Readme.Core.Tests/GoldenFilesTests.cs`.

- [ ] **Step 1: Install the .NET SDK on the Mac.** Run `brew install --cask dotnet-sdk`, then `dotnet test windows/Readme.Core.Tests` from the repo root. Expected: the existing suite passes, which is the baseline. Record any failures in the ledger before going on.
- [ ] **Step 2: Write the failing tests.**
  - Swift `libraryFileLoads`: also expect the long book's `collectionIDs`, `progress == 0.42` and `finishedAt`.
  - New Swift `collectionsFileLoads`: a store over a folder with both golden files has the one collection, named "Self-Help".
  - Windows `LibraryFileLoads`: the same expectations.
  - New Windows `CollectionsFileIsWrittenAsTheMacWritesIt`: deserialize and reserialize `collections.json` with `Json.Library` and `AssertSameJson`.
  - The existing `LibraryFileIsWrittenAsTheMacWritesIt` covers the new keys once the golden file has them.
- [ ] **Step 3: Run** `scripts/test.sh GoldenFilesTests` (Mac). Expected: PASS, since the Mac already writes these. Run `dotnet test windows/Readme.Core.Tests --filter GoldenFilesTests`. Expected: FAIL to build, with no `CollectionIds` or `Progress`. This task's Windows half goes green in Tasks 2 and 3.
- [ ] **Step 4: Commit** `test: golden files with collections and reading progress`.

### Task 2: Collections in Readme.Core

**Files:**
- Create: `windows/Readme.Core/Model/BookCollection.cs`
- Modify: `windows/Readme.Core/Model/Book.cs`, `windows/Readme.Core/Storage/LibraryStore.cs`, `windows/Readme.Core/Layout/ShelfSearch.cs` (make `Fold` `public`)
- Test: `windows/Readme.Core.Tests/CollectionStoreTests.cs` (new, a port of `ReadmeTests/CollectionStoreTests.swift`)

**Interfaces:**
- Produces:
  - `public sealed record BookCollection { required Guid Id; required string Name; required DateTimeOffset CreatedAt }`, with `const int MaxNameLength = 40` and `static IReadOnlyList<string> SuggestedNames`.
  - `static string? CleanName(string)` (trimmed, capped, null if empty), `static string Key(string)` (`ShelfSearch.Fold`), and `static IReadOnlyList<string> Suggestions(IEnumerable<BookCollection> existing)`.
  - `Book.CollectionIds: IReadOnlyList<Guid>` with `[JsonPropertyName("collectionIDs")]`, default `[]`. A missing key reads as empty.
  - `LibraryStore`:
    - `IReadOnlyList<BookCollection> Collections`, sorted with `string.Compare(a, b, StringComparison.CurrentCultureIgnoreCase)` to match `localizedStandardCompare` for plain names.
    - Lookups: `BookCollection? Collection(Guid id)`, `BookCollection? Collection(string name)`.
    - Changes: `BookCollection? CreateCollection(string name)` (returns the existing one on a duplicate), `bool RenameCollection(Guid id, string name)`, `void DeleteCollection(Guid id)` (strips memberships), `void SetCollection(Guid id, bool member, IEnumerable<string> ids)`.
    - For imports: `void JoinCollections(IEnumerable<string> names, string id)`.
- `collections.json` is written whole, through `Files.WriteJson` like `library.json`, and read in the constructor. Stale IDs are pruned at load only when the file is missing or reads cleanly.

- [ ] **Step 1: Port the tests.**
  - Every test in `CollectionStoreTests.swift`, same names in PascalCase, same values, using `TempFolder` and `Samples.Book`: create trims and caps; a duplicate returns the existing one; alphabetical order; rename refuses another's name; delete strips memberships; membership on a selection.
  - Saved and reloaded; an old library file loads; unknown IDs are dropped; a corrupt collections file keeps the IDs; joining by name; suggestions leave out existing ones.
- [ ] **Step 2: Run** `dotnet test windows/Readme.Core.Tests --filter CollectionStoreTests`. Expected: build fails.
- [ ] **Step 3: Implement** to the interfaces above, following `LibraryStore.swift` line by line. All changes go through the existing `Change`/`Update` helpers, plus a twin `ChangeCollections` that writes `collections.json`.
- [ ] **Step 4: Run** `dotnet test windows/Readme.Core.Tests`. Expected: PASS, apart from the golden progress expectations, which go green in Task 3.
- [ ] **Step 5: Commit** `feat(windows): collections in the library store`.

### Task 3: Reading progress in Readme.Core

**Files:**
- Create: `windows/Readme.Core/Reader/FinishRule.cs`
- Modify: `windows/Readme.Core/Model/Book.cs`, `windows/Readme.Core/Storage/LibraryStore.cs`
- Test: `windows/Readme.Core.Tests/ReadingProgressStoreTests.cs` and `FinishRuleTests.cs` (ports of the Swift files of the same names)

**Interfaces:**
- Produces:
  - `Book.Progress: double?`, `Book.FinishedAt: DateTimeOffset?`, and `[JsonIgnore]` `IsStarted` and `IsFinished`.
  - `static double Book.ProgressOf(ReaderLocation)`: 1 at the end, else the fraction clamped to 0…1.
  - `LibraryStore.MarkRead(string id, ReaderLocation location, bool finishing = false)`
  - `LibraryStore.SetFinished(IEnumerable<string> ids, bool finished)`
  - `LibraryStore.RestoreFinished(string id, DateTimeOffset date)`
  - `ApplyImported` also sets `Progress`.
  - The constructor fills a missing `Progress` from `Positions.Location(id)` and never finishes anything.
  - `public static class FinishRule { const double Threshold = 0.95; static bool Finishes(ReaderLocation? previous, ReaderLocation location, bool byTurning) }`, the same body as `FinishRule.swift`.
- Dates set by the store go through `ReferenceDateConverter.Normalize`, as `PinnedAt` does.

- [ ] **Step 1: Port the tests.** All 9 of `ReadingProgressStoreTests.swift` and all 5 of `FinishRuleTests.swift`, with a fixed clock (`now:`).
- [ ] **Step 2: Run** `dotnet test windows/Readme.Core.Tests --filter "ReadingProgressStoreTests|FinishRuleTests"`. Expected: build fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `dotnet test windows/Readme.Core.Tests`. Expected: PASS, golden files included.
- [ ] **Step 5: Commit** `feat(windows): reading progress and finished dates`.

### Task 4: The new bundle keys

**Files:**
- Modify: `windows/Readme.Core/Library/LibraryBundle.cs` (`BundledBook.Collections: IReadOnlyList<string>?`, `BundledBook.FinishedAt: DateTimeOffset?`)
- Modify: `windows/Readme.Core/Library/LibraryExporter.cs`, `windows/Readme.Core/Library/LibraryImporter.cs` (`AddAsync`, `CombineAsync`)
- Test: `windows/Readme.Core.Tests/LibraryBundleTests.cs`

**Interfaces:**
- Consumes: `JoinCollections` (Task 2), `RestoreFinished` and `ApplyImported` with progress (Task 3).
- Exporter: `Collections` holds the book's collection names sorted (`CurrentCultureIgnoreCase`), or null when it's in none. `FinishedAt` is `book.FinishedAt`.
- Importer:
  - **New book:** `JoinCollections(contents.Info.Collections ?? [], id)`, and `RestoreFinished` when the bundle has a date.
  - **Combine:** the same two calls, after the place is merged.
  - **Keep Mine:** untouched.

- [ ] **Step 1: Port the tests** from the Swift `LibraryBundleTests` and `LibraryImporterTests`:
  - `collectionsKeyLeftOutWhenNone` and `finishedAtKeyLeftOutWhenNone`.
  - New books join their collections; names match across case.
  - Existing books and collections, for both choices; a bundle without collections.
  - New books keep their finished date and progress.
  - An unfinished book here, for both choices; a book finished here keeps its date.
  - Use the existing helpers in `windows/Readme.Core.Tests/LibraryBundleTests.cs`.
- [ ] **Step 2: Run** `dotnet test windows/Readme.Core.Tests --filter LibraryBundleTests`. Expected: build fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `dotnet test windows/Readme.Core.Tests`. Expected: PASS. Also run `scripts/test.sh GoldenFilesTests` on the Mac. Expected: the Windows-made `windows.readmelibrary` still opens.
- [ ] **Step 5: Commit** `feat(windows): carry collections and finished dates in bundles`.

### Task 5: Shelf logic in Readme.Core

**Files:**
- Create:
  - `windows/Readme.Core/Library/ShelfFilter.cs`: `abstract record ShelfFilter` with `All`, `Reading`, `Finished` and `Collection(Guid Id)` as singletons/records, so equality works.
  - `windows/Readme.Core/Library/ShelfCollections.cs`
  - `windows/Readme.Core/Layout/ChipRowLayout.cs`
- Modify: `windows/Readme.Core/Library/Shelf.cs` (`ShelfSelection`, `ShelfText`)
- Test: `windows/Readme.Core.Tests/ShelfCollectionsTests.cs`, `ChipRowLayoutTests.cs` and `ReadingMarksTests.cs` (new); `LibraryTests.cs` for the selection titles

**Interfaces** (names as in the Swift, PascalCase):
- `ShelfCollections`:
  - State: `ShelfFilter Filter`, `Guid? ActiveId` (get/set over `Filter`), and the `CollectionSheet` and `ConfirmingDelete` state, raising a `Changed` event like `ShelfSelection`.
  - Instance methods: `ShelfFilter FilterIn(LibraryStore)`, `void Settle(LibraryStore)`, `void ShowAll()`, `void Delete(Guid, LibraryStore)`, `void AddImported(IEnumerable<string> ids, LibraryStore)`.
  - Static: `IReadOnlyList<Book> Shown(IEnumerable<Book>, ShelfFilter)` (Finished is newest finished first), `IReadOnlyList<ShelfFilter> BuiltInChips(IEnumerable<Book>)`, `bool ShowsChipRow(LibraryStore)`, `IReadOnlyList<string> ShelfOrder(LibraryStore, ShelfFilter)` and `void Escape(ShelfSearch, ShelfSelection, ShelfCollections)`.
  - Text: `string EmptyLine(string name)`, `(string Title, string Message) DeleteText(string name, int count)`.
- `ChipRowLayout`:
  - Constants: `Leading = 88`, `SearchGap = 16`, `Gap = 8`.
  - `ChipFit Fit(IReadOnlyList<double> widths, int active, double available, double moreWidth, double addWidth)`, a port of `ChipRowLayout.swift`.
- `ShelfSelection`:
  - `static string FinishMenuTitle(int count, bool allFinished)`, `static bool IsEveryBook(IEnumerable<Book>, Guid)`, `static string RemoveFromTitle(string name)`.
  - `static string AddsLine(int count)` and `static string? RenameConflict(string name, Guid renaming, IEnumerable<BookCollection>)`, from `CollectionNameSheet.swift`.
- `ReadingMarks` (a static class in `Shelf.cs`):
  - `int Percent(double)`
  - `string Tooltip(Book, DateTimeOffset now, CultureInfo culture)` (day and abbreviated month, with the year when it's not this year)
  - `string AccessibilityLabel(Book)`
  - `string? LedgeLine(Book)`, built on the existing `ShelfText.ProgressLine`

- [ ] **Step 1: Port the tests.** Every test in `ShelfCollectionsTests.swift`, `ChipRowLayoutTests.swift`, `ReadingMarksTests.swift` (with `new CultureInfo("en-GB")`), `CollectionNameSheetTests.swift`, and the finish, every-book and remove-from title tests in `ShelfSelectionTests.swift`. Same values.
- [ ] **Step 2: Run** `dotnet test windows/Readme.Core.Tests`. Expected: build fails on the new types.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `dotnet test windows/Readme.Core.Tests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(windows): shelf filters, chip layout and reading marks in Core`.

> Tasks 6–8 run on the Windows machine: `dotnet build -p:Platform=x64 -r win-x64`, the app itself, and the self-checks (`Readme.exe --checks`, see `windows/README.md`).

### Task 6: Finishing by turning pages in the reader

**Files:**
- Modify: `windows/Readme.App/Reader/ReaderView.cs`, `windows/Readme.App/Shell/AppCoordinator.cs`
- Modify: `windows/Readme.App/Shell/SelfChecks.cs` (a new `finishing` mode, following the existing modes)

**Interfaces:**
- `ReaderView.Read` becomes `event Action<string, ReaderLocation, bool>?`, where the last argument is `finishing`. `AppCoordinator` passes it to `MarkRead(id, location, finishing)`. Windows has no `ReadMarker` throttle, so nothing needs merging.
- In `ReaderView`:
  - **State:** add `int _jumpsLanding`, `bool _followingLink` and `ReaderLocation? _lastPlace`, reset when a book opens.
  - **Jumps:** in `Jump`, wrap `go` so the count goes up when the coordinator runs it, inside `_turns.JumpAsync(() => { _jumpsLanding++; try { return await go(_book); } finally { _jumpsLanding--; } })`.
  - **Links:** `LinkFollowed += landed => _followingLink = !landed`.
  - **Relocated:** compute `FinishRule.Finishes(_lastPlace, location, byTurning: _jumpsLanding == 0 && !_followingLink)` before setting `_lastPlace = location`, and pass it to `Keep`.

- [ ] **Step 1: Write the self-check `finishing`.** It opens `long.epub` from a test library and does three things in turn:
  - Go to Page to 90% and turn forward until past 95%: expect `finishedAt` set.
  - Unmark, then Home and End: expect it not finished.
  - End with an immediate turn back: expect it not finished.

  Write the results to `finishing.json` as the other modes do.
- [ ] **Step 2: Run** the self-check. Expected: fails, since nothing finishes yet.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the `finishing` self-check, then all self-checks. Expected: PASS.
- [ ] **Step 5: Commit** `feat(windows): finish a book by turning pages past 95%`.

### Task 7: Chips, collections and reading marks on the shelf

**Files:**
- Create:
  - `windows/Readme.App/Library/CollectionChips.cs`: the row, the More chip as a `DropDownButton` with a `MenuFlyout`, **+**, and right-click Rename… / Delete Collection on user chips only.
  - `windows/Readme.App/Library/CollectionNameDialog.cs`: a `ContentDialog` for New and Rename, with a name box, suggestion buttons in a wrapping `ItemsRepeater`/`VariableSizedWrapGrid`, and the `AddsLine` text.
- Modify:
  - `windows/Readme.App/Library/LibraryView.cs`: filter `Others`, `Found` and the ledge through `ShelfCollections`; the chip row on the search's line at `ChipRowLayout.Leading`; 36 pt top padding when `ShowsChipRow`; the empty-collection line; Esc through `ShelfCollections.Escape`; `Settle` after each `Rebuild`; the delete confirmation as a `ContentDialog`; and drops joining the active collection.
  - `windows/Readme.App/Library/BookCoverView.cs`:
    - The bar slot under the cover.
    - The double tick, as a `Path` on a `RadialGradientBrush` corner shade that's clipped to the cover.
    - `ToolTipService.SetToolTip(ReadingMarks.Tooltip(…))`, except on the ledge.
    - `AutomationProperties.SetName(ReadingMarks.AccessibilityLabel(book))`.
  - `windows/Readme.App/Library/ShelfStyle.cs`: `Field = #241F1A`, used by the search box and the chips.
  - `windows/Readme.App/Shell/AppCoordinator.cs`: bundle imports join the active collection.
- Modify: `LibraryView.FillMenu`, to the menu order in Global Constraints. The Add to Collection submenu uses `ToggleMenuFlyoutItem`s, a separator and New Collection….

- [ ] **Step 1:** Add self-check screenshots for these states, following the existing screenshot modes:
  - the shelf with a collection active
  - the More menu open with the search open
  - a finished book and a book part-read
  - the New Collection dialog
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run** the self-checks and look at the screenshots against the mockups (the canvas linked in both specs). Then try by hand:
  - A chip whose last book is finished.
  - Rename to an existing name, which shows the conflict line.
  - Delete with and without books.
  - Drop a book while a collection is showing.
  - Ctrl+F inside the Finished chip.
  - Esc order.
  - The tooltip delay.
  - Narrator on a chip ("Self-Help, collection, selected") and on a cover ("…, 42% read").
- [ ] **Step 4: Commit** `feat(windows): collection chips, progress bars, finished ticks and tooltips`.

### Task 8: Edge clicks, round trip and checklist

**Files:**
- Modify: `docs/Readme for Windows checklist.md`

- [ ] **Step 1: Edge clicks.** The `fix/edge-click-selection` Windows code is on `main` but has never been compiled. Build it, run `dotnet test windows/Readme.Core.Tests` (the `EdgeClick` tests), and try by hand the list in the checklist's current-state entry: drag, double and triple click, quick clicks on the margin, a contents link near both edges, a click while the window is behind another app, and a key turn with text selected. Fix anything broken with a test or self-check first.
- [ ] **Step 2: Round trip.** On the Mac:
  - Put two books in collections and finish one, then export a `.readmelibrary` and also save it as `ReadmeTests/Fixtures/Golden/mac.readmelibrary`. This is the "still to add" in the golden README.
  - Import it on Windows with Combine, add a book to a collection, finish another, export, and import back on the Mac.
  - Expected: collections and finished books intact both ways.
  - Add a Windows `GoldenFilesTests` case that opens `mac.readmelibrary` and checks its collections and `finishedAt`.
- [ ] **Step 3: Checklist.**
  - Tick the Collections and Reading progress items.
  - Update "Current state" (phase, branch, last thing done, next step).
  - Note anything still to try by hand.
- [ ] **Step 4: Run** `dotnet test windows/Readme.Core.Tests` and, on the Mac, `scripts/test.sh GoldenFilesTests`. Expected: PASS.
- [ ] **Step 5: Commit** `docs: Windows has collections and reading progress`.
